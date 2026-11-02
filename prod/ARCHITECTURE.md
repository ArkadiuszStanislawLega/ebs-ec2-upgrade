# Architektura Techniczna, Przepływ Danych i Model Uprawnień IAM

Dokument opisuje szczegółowy przepływ sygnałów sterujących, strukturę payloadów JSON oraz granice autoryzacji IAM w układzie **AWS EBS gp3 Auto-Throughput Scaler (Multi-Volume Sidecar Control Plane)**.

---

## 1. Topologia Systemu i Granice IAM (Schemat Terminalowy ASCII)

```text
====================================================================================================
                  ŚCIEŻKA 1: REAKTYWNY SCALE-UP (PUSH / EVENT-DRIVEN, ~2-3 MIN)
====================================================================================================

 [ Wolumeny EBS gp3 (Oracle DB) ]
   │  (vol-01, vol-02, ..., vol-07)
   │
   │ 1. Strumień telemetrii I/O co 60s (VolumeReadBytes, VolumeWriteBytes)
   ▼
 [ CloudWatch Metric Math Alarms (for_each = var.volumes) ]
   │  Wzór: (m_read + m_write) / 60 / 1048576 >= 105 MB/s (2 z 3 punktów)
   │
   │ 2. Zmiana stanu OK -> ALARM: Publikacja JSON (SNS:Publish)
   ▼
 [ Wspólny Temat SNS: oracle-ebs-scaler-scale-up-topic ]
   │
   │ 3. Asynchroniczny Push (lambda:InvokeFunction)
   │    🛡️ Autoryzacja Wejściowa: Lambda Resource Policy (AllowExecutionFromSNS, SourceArn=SNS_ARN)
   ▼
====================================================================================================
                  CENTRALNY SILNIK STERUJĄCY: AWS LAMBDA (oracle-ebs-scaler)
                  Konfiguracja w RAM: VOLUMES_CONFIG_JSON (mapa wszystkich dysków)
                  🛡️ Tożsamość Wyjściowa: sts:AssumeRole -> oracle-ebs-scaler-lambda-role
====================================================================================================
   ▲                                      │                           │                        │
   │ 4. Cykliczny Trigger co 30 min       │ 5. Telemetria (Read-Only) │ 6. Zmiana QoS (Write)  │ 7. Audyt JSON
   │    Payload: {"action": "scale_down"} │    Uprawnienia IAM:       │    Uprawnienia IAM:    │    Uprawnienia IAM:
   │    🛡️ Autoryzacja Wejściowa:         │    - ec2:DescribeVolumes* │    - ec2:ModifyVolume  │    - logs:CreateLogStream
   │    Lambda Resource Policy            │    - cw:DescribeAlarms    │    Tylko dla jawnej    │    - logs:PutLogEvents
   │    (AllowExecutionFromEventBridge)   │    - cw:GetMetricData     │    listy ARN z tfvars! │    Zasób: /aws/lambda/*
   │    Zasób: *                          ▼                           ▼                        ▼
 [ EventBridge Scheduler ]          [ CloudWatch & EC2 API ]    [ EBS Control Plane ]    [ CloudWatch Logs ]
   (rate(30 minutes))                 (Weryfikacja 4 Guard        (Podbicie do 1000 MB/s   (/aws/lambda/
                                       Clauses przed zejściem)     lub zejście do 125 MB/s) oracle-ebs-scaler)
====================================================================================================
                  ŚCIEŻKA 2: PROAKTYWNY SCALE-DOWN (BATCH POLLING CO 30 MIN)
====================================================================================================
```

---

## 2. Diagram Komponentów i Granic Bezpieczeństwa IAM (Mermaid.js)

```mermaid
flowchart TB
    subgraph Storage["Warstwa Danych (Moduł Bazowy Terraform EC2)"]
        EBS1[("EBS gp3: vol-01..vol-N<br/>Stan: in-use<br/>Baza: 125 MB/s | 3000 IOPS<br/>Szczyt: 1000 MB/s | 4000 IOPS")]
    end

    subgraph Triggers["Warstwa Detekcji i Wyzwalaczy (Ingress)"]
        CW_ALARM["CloudWatch Metric Math Alarms<br/>(Po 1 alarmie na każdy dysk)<br/>Próg: min. 105 MB/s (2 z 3 min)"]
        SNS["AWS SNS Topic<br/>oracle-ebs-scaler-scale-up-topic"]
        EB["Amazon EventBridge Rule<br/>oracle-ebs-scaler-scaledown-check<br/>Harmonogram: rate(30 minutes)"]
    end

    subgraph SecurityIngress["Granica Autoryzacji Wejściowej (Lambda Resource Policy)"]
        PERM_SNS["aws_lambda_permission: AllowExecutionFromSNS<br/>Principal: sns.amazonaws.com<br/>Condition: SourceArn == SNS Topic ARN"]
        PERM_EB["aws_lambda_permission: AllowExecutionFromEventBridge<br/>Principal: events.amazonaws.com<br/>Condition: SourceArn == EventBridge Rule ARN"]
    end

    subgraph Compute["Silnik Sterujący (Python 3.12)"]
        LAMBDA["AWS Lambda: oracle-ebs-scaler<br/>ENV: VOLUMES_CONFIG_JSON<br/>Dispatcher: scale_up | scale_down"]
    end

    subgraph SecurityEgress["Granica Autoryzacji Wyjściowej (IAM Execution Role: oracle-ebs-scaler-lambda-role)"]
        IAM_MOD["Sid: ModifyEnrolledVolumesOnly<br/>Allow: ec2:ModifyVolume<br/>Resource: TYLKO lista ARN dysków z var.volumes<br/>(Brak ec2:DeleteVolume / ec2:DetachVolume)"]
        IAM_READ["Sid: ReadVolumeAndCloudWatchTelemetry<br/>Allow: ec2:DescribeVolumes, ec2:DescribeVolumesModifications,<br/>cloudwatch:DescribeAlarms, cloudwatch:GetMetricData<br/>Resource: *"]
        IAM_LOGS["Sid: WriteLambdaLogs<br/>Allow: logs:CreateLogStream, logs:PutLogEvents<br/>Resource: arn:aws:logs:.../aws/lambda/oracle-ebs-scaler:*"]
    end

    subgraph Observability["Telemetria i Audyt"]
        CW_LOGS[("CloudWatch Log Group<br/>/aws/lambda/oracle-ebs-scaler<br/>Retencja: 90 dni")]
        CW_METRICS[("CloudWatch Metrics API<br/>AWS/EBS Namespace")]
    end

    EBS1 -. "1. Publikacja metryk co 60s<br/>(VolumeReadBytes + VolumeWriteBytes)" .-> CW_METRICS
    CW_METRICS --> CW_ALARM
    CW_ALARM -- "2. Stan ALARM -> Publikacja JSON" --> SNS
    SNS -- "3a. Wyzwolenie Push" --> PERM_SNS
    EB -- "3b. Wyzwolenie Cykliczne<br/>payload: action=scale_down" --> PERM_EB
    PERM_SNS --> LAMBDA
    PERM_EB --> LAMBDA

    LAMBDA -- "Przyjęcie roli (sts:AssumeRole)" --> IAM_MOD
    LAMBDA -- "Przyjęcie roli (sts:AssumeRole)" --> IAM_READ
    LAMBDA -- "Przyjęcie roli (sts:AssumeRole)" --> IAM_LOGS

    IAM_MOD == "ec2:ModifyVolume<br/>(Throughput, Iops)" ==> EBS1
    IAM_READ -. "Odczyt stanu dysku, czasu modyfikacji<br/>i pików z ostatnich 60 min" .-> CW_METRICS
    IAM_READ -. "ec2:DescribeVolumes*" .-> EBS1
    IAM_LOGS -- "Strumieniowanie zdarzeń JSON" --> CW_LOGS
```

---

## 3. Diagram Sekwencji i Walidacji Guard Clauses (Mermaid.js)

```mermaid
sequenceDiagram
    autonumber
    participant EBS as AWS EBS Volume (gp3)
    participant CW as CloudWatch (Alarms & Metrics)
    participant SNS as AWS SNS Topic
    participant EB as EventBridge (co 30m)
    participant L as Lambda (oracle-ebs-scaler)
    participant LOG as CloudWatch Logs

    Note over EBS,LOG: SCENARIUSZ A: Przeciążenie dysku podczas fakturowania (Scale-Up)
    EBS->>CW: Zrzut metryk VolumeReadBytes + VolumeWriteBytes (co 1 min)
    CW->>CW: Ewaluacja Metric Math: (read + write)/60/1048576 min. 105 MB/s (2 z 3 min)
    CW->>SNS: Zmiana stanu na ALARM -> Wysłanie wiadomości JSON z metrykami
    SNS->>L: InvokeFunction (Autoryzacja przez AllowExecutionFromSNS)
    L->>L: resolve_invocation() -> Wykrycie źródła aws:sns
    L->>L: extract_volume_id_from_sns() -> Wyciągnięcie VolumeId z Trigger.Metrics
    L->>L: Walidacja czy VolumeId istnieje w VOLUMES_CONFIG_JSON
    L->>EBS: ec2:DescribeVolumes (Sprawdzenie aktualnego Throughput i IOPS)
    L->>EBS: ec2:DescribeVolumesModifications (Sprawdzenie czy stan != modifying)
    alt Guard Clauses spełnione (Throughput poniżej 1000 MB/s oraz brak aktywnej modyfikacji)
        L->>EBS: ec2:ModifyVolume(VolumeId, Throughput=1000, Iops=4000)
        L->>LOG: PutLogEvents: event=ebs_modified, direction=scale_up
    else Limit API AWS (VolumeModificationRateExceeded)
        L->>LOG: PutLogEvents (ERROR): event=ebs_modify_deferred, direction=scale_up
    end

    Note over EBS,LOG: SCENARIUSZ B: Cykliczna weryfikacja zejścia w dół (Scale-Down)
    EB->>L: InvokeFunction payload: action=scale_down (AllowExecutionFromEventBridge)
    L->>L: Pobranie listy wszystkich dysków z VOLUMES_CONFIG_JSON
    loop Niezależna iteracja dla każdego dysku (izolacja try/except)
        L->>EBS: [Guard 1] ec2:DescribeVolumes (Czy aktualny Throughput powyżej 125 MB/s?)
        L->>EBS: [Guard 2] ec2:DescribeVolumesModifications (Czy stan != modifying i minęło min. 60 min?)
        L->>CW: [Guard 3] cloudwatch:DescribeAlarms (Czy alarm dla dysku ma stan OK?)
        L->>CW: [Guard 4] cloudwatch:GetMetricData (Czy max 1-min pik z ostatnich 60 min poniżej 85 MB/s?)
        alt Wszystkie 4 Guard Clauses spełnione
            L->>EBS: ec2:ModifyVolume(VolumeId, Throughput=125, Iops=3000)
            L->>LOG: PutLogEvents (INFO): event=ebs_modified, direction=scale_down
        else Którykolwiek Guard Clause odrzucił zejście
            L->>LOG: PutLogEvents (INFO): event=scale_down_skipped, reason=...
        end
    end
```

---

## 4. Szczegółowa Matryca Komunikacji, Payloadów i Uprawnień

| Krok | Nadawca (Źródło) | Odbiorca (Cel) | Mechanizm Autoryzacji (IAM / Policy) | Przesyłane Dane (Payload) | Walidacja i Reakcja Odbiorcy |
|---|---|---|---|---|---|
| **1** | **EBS Hypervisor (Nitro)** | **CloudWatch Metrics** | Wewnętrzny mechanizm AWS Control Plane (bezpłatny strumień `AWS/EBS`). | Surowe liczniki bajtów: `VolumeReadBytes` oraz `VolumeWriteBytes` (Sum, okres 60s). | Agregacja danych w szeregach czasowych przypisanych do wymiaru `VolumeId`. |
| **2** | **CloudWatch Alarm** | **SNS Topic** (`*-scale-up-topic`) | Wbudowana rola serwisowa CloudWatch Alarms. | Obiekt JSON stanu alarmu (`NewStateValue: "ALARM"`, tablica `Trigger.Metrics` z zaszytym `VolumeId`). | Temat SNS przyjmuje wiadomość i natychmiast rozsyła ją do zasubskrybowanych endpointów. |
| **3a** | **SNS Topic** | **AWS Lambda** (`oracle-ebs-scaler`) | **Lambda Resource Policy:** `AllowExecutionFromSNS` (`Principal: sns.amazonaws.com`, weryfikacja `SourceArn`). | Koperta SNS (`Records[0].EventSource == "aws:sns"`), wewnątrz zserializowany JSON z CloudWatcha. | Funkcja `extract_volume_id_from_sns()` parsuje zagnieżdżone wymiary Metric Math, weryfikuje obecność dysku w `VOLUMES_CONFIG_JSON` i kieruje wywołanie do `scale_up_single_volume()`. |
| **3b** | **EventBridge Rule** (`rate(30 minutes)`) | **AWS Lambda** (`oracle-ebs-scaler`) | **Lambda Resource Policy:** `AllowExecutionFromEventBridge` (`Principal: events.amazonaws.com`, weryfikacja `SourceArn`). | Statyczny obiekt JSON: `{"action": "scale_down"}`. | Funkcja `resolve_invocation()` kieruje ruch przez `ACTION_DISPATCHER` do pętli wsadowej `handle_scale_down_dispatch()`, która bada każdy dysk z osobna. |
| **4** | **AWS Lambda** | **EC2 API & CloudWatch API** | **IAM Execution Role:** `oracle-ebs-scaler-lambda-role` (polityka `ReadVolumeAndCloudWatchTelemetry`, `Resource: "*"`). | Zapytania HTTPS podpisane SigV4: `DescribeVolumes`, `DescribeVolumesModifications`, `DescribeAlarms`, `GetMetricData`. | Sprawdzenie 4 warunków brzegowych (Guard Clauses): aktualnego pasma, braku statusu `modifying`, upływu 60 minut od ostatniej zmiany, stanu `OK` na alarmie oraz maksymalnego piku z ostatnich 60 min poniżej 85 MB/s. |
| **5** | **AWS Lambda** | **AWS EBS Control Plane** | **IAM Execution Role:** `oracle-ebs-scaler-lambda-role` (polityka `ModifyEnrolledVolumesOnly`, `Resource:` **wyłącznie jawna lista ARN dysków z Terraforma**). | Wywołanie `ec2:ModifyVolume` z parametrami `VolumeId`, `Throughput` (1000 lub 125) oraz `Iops` (4000 lub 3000). | Kontroler EBS online przydziela lub zwalnia pasmo na łączu Nitro bez restartu EC2 i bez przerywania transakcji Oracle DB. W razie przekroczenia limitu API (6h cooldown), wyjątek `VolumeModificationRateExceeded` jest łagodnie przechwytywany (model EAFP). |
| **6** | **AWS Lambda** | **CloudWatch Logs** | **IAM Execution Role:** `oracle-ebs-scaler-lambda-role` (polityka `WriteLambdaLogs` ograniczona do `/aws/lambda/oracle-ebs-scaler:*`). | Ustrukturyzowany rekord JSON (`event`, `volume_id`, `direction`, `reason`, `max_mbps`). | Zapis w strumieniu logów z retencją 90 dni pod audyt operacyjny i skrypt `ops_control.sh logs`. |
