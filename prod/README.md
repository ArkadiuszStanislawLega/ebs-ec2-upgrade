# AWS EBS gp3 Auto-Throughput Scaler (Multi-Volume Control Plane)

Autonomiczny układ sterujący (Sidecar Control Plane) do dynamicznego skalowania przepustowości (`Throughput`) oraz `IOPS` dla wolumenów AWS EBS `gp3` obsługujących bazy danych Oracle (fakturowanie, procesy batchowe, RMAN).

Rozwiązanie działa całkowicie niezależnie od zewnętrznych modułów Terraform zarządzających instancjami EC2 oraz dyskami twardymi – nie tworzy i nie niszczy wolumenów EBS, lecz steruje ich parametrami QoS poprzez AWS API.

---

## 1. Architektura i Zasada Działania

Układ wykorzystuje jedną centralną funkcję AWS Lambda do obsługi dowolnej liczby wolumenów EBS zdefiniowanych w mapie `volumes`:

1. **Detekcja przeciążenia (Scale-Up):**
   * Dla każdego monitorowanego dysku tworzony jest alarm CloudWatch oparty o **Metric Math**, wyliczający co 60 sekund łączny transfer odczytu i zapisu w MiB/s:
     `(VolumeReadBytes + VolumeWriteBytes) / PERIOD(VolumeReadBytes) / 1048576`
   * Gdy transfer przekroczy próg `scale_up_threshold_mbps` (domyślnie `105 MB/s`) w `2 z 3` ostatnich minut, alarm zmienia stan na `ALARM` i publikuje powiadomienie JSON na wspólny temat SNS.
   * Funkcja Lambda odczytuje `VolumeId` z wymiarów metryki wewnątrz wiadomości SNS i wywołuje `ec2:ModifyVolume`, podbijając parametry dysku do `high_throughput` (domyślnie `1000 MB/s`) oraz `high_iops` (domyślnie `4000 IOPS`, zgodnie z wymogiem AWS `gp3`: minimum 1 IOPS na każde 0.25 MB/s pasma).

2. **Powrót do parametrów bazowych (Scale-Down z histerezą):**
   * Wspólna reguła EventBridge wywołuje funkcję Lambda cyklicznie (domyślnie co `30 minut`) z akcją `scale_down`.
   * Lambda iteruje po wszystkich skonfigurowanych dyskach. Każdy dysk posiada niezależną izolację błędów (`try/except`).
   * Dysk zostaje przywrócony do parametrów bazowych (`125 MB/s`, `3000 IOPS`) **wyłącznie wtedy**, gdy spełnione są jednocześnie 4 warunki (Guard Clauses):
     1. Aktualny throughput dysku jest wyższy niż `base_throughput`.
     2. Od momentu ostatniej modyfikacji upłynęło minimum `min_minutes_before_scaledown` (domyślnie `60 minut` – chroni przed przedwczesnym zbiciem pasma w przerwach między krokami wieloetapowego bilingu).
     3. Alarm CloudWatch dla tego dysku wrócił do stanu `OK`.
     4. Maksymalny 1-minutowy pik transferu z ostatnich `lookback_minutes` (domyślnie `60 minut`) w CloudWatch był niższy niż `scale_down_threshold_mbps` (domyślnie `85 MB/s`).

3. **Odporność na limity AWS API (Model EAFP):**
   * Jeśli podczas próby zmiany parametrów pula żetonów modyfikacji po stronie AWS EBS Control Plane jest wyczerpana i API zwróci wyjątek `VolumeModificationRateExceeded` lub `IncorrectModificationState`, Lambda przechwytuje błąd, loguje zdarzenie `ebs_modify_deferred` i ponawia próbę w kolejnym cyklu EventBridge.

---

## 2. Wymagania Wstępne i Kompatybilność

* **Typ wolumenu:** Wyłącznie `gp3` w stanie `in-use` (weryfikowane automatycznie przez Terraform `data "aws_ebs_volume"`).
* **Przepustowość instancji EC2:** Aby wolumen osiągnął fizycznie `1000 MB/s` (8 Gbps), instancja EC2 musi wspierać pasmo EBS na poziomie minimum 8 Gbps (np. rodzina `m6i`, `c6i`, `r6i`). Sprawdź limity skryptem `scripts/pre_flight_audit.py`.
* **Zewnętrzny moduł Terraform (State Drift):** Jeśli zewnętrzny moduł Terraform tworzący dysk ma jawnie zdefiniowane domyślne wartości `throughput = 125` lub `iops = 3000`, należy w tamtym module dodać blok:
  ```hcl
  lifecycle {
    ignore_changes = [throughput, iops]
  }
  ```

---

## 3. Wdrożenie i Dodawanie Nowych Dysków

### Pierwsze wdrożenie
```bash
# 1. Uruchomienie lokalnych testów jednostkowych
pytest -v tests/test_scaler_unit.py

# 2. Konfiguracja listy dysków
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edytuj terraform.tfvars i wpisz identyfikatory vol-xxxxxxxxxxxxxxxxx w mapie 'volumes'

# 3. Wdrożenie infrastruktury sterującej
terraform init
terraform apply
```

### Jak dodać kolejny dysk do automatu?
Dopisz identyfikator nowego wolumenu do mapy `volumes` w pliku `terraform/terraform.tfvars`:

```hcl
volumes = {
  "vol-0663e1160ec359efa" = {} # Dysk 1: domyślny profil (125 -> 1000 MB/s, 3000 -> 4000 IOPS)
  "vol-0999a888b777c666d" = {} # Dysk 2: domyślny profil

  # Dysk 3: niestandardowy profil (np. dysk z wyższym bazowym IOPS)
  "vol-01112222333344445" = {
    base_throughput           = 250
    high_throughput           = 1000
    base_iops                 = 6000
    high_iops                 = 6000
    scale_up_threshold_mbps   = 210
    scale_down_threshold_mbps = 160
  }
}
```
Następnie wykonaj `terraform apply`. Terraform automatycznie utworzy nowy alarm CloudWatch, rozszerzy tablicę `VOLUMES_CONFIG_JSON` w Lambdzie oraz dopisze ARN nowego dysku do polityki IAM (`ModifyEnrolledVolumesOnly`).

---

## 4. Operacje Utrzymaniowe (Day-2 Ops)

Do zarządzania automatem z poziomu CLI służy skrypt `scripts/ops_control.sh`:

* **Sprawdzenie statusu wszystkich alarmów i reguły EventBridge:**
  ```bash
  ./scripts/ops_control.sh status
  ```
* **Awaryjne wstrzymanie automatu (Kill-Switch na czas prac serwisowych DBA):**
  ```bash
  ./scripts/ops_control.sh disable
  ```
* **Ponowne uzbrojenie automatu po oknie serwisowym:**
  ```bash
  ./scripts/ops_control.sh enable
  ```
* **Podgląd ustrukturyzowanych logów JSON z Lambdy na żywo:**
  ```bash
  ./scripts/ops_control.sh logs
  ```
* **Wymuszenie natychmiastowej ewaluacji Scale-Down dla wszystkich dysków:**
  ```bash
  ./scripts/ops_control.sh force-scaledown
  ```

### Ręczne podbicie pojedynczego dysku z CLI (na żądanie przed nietypowym jobem)
```bash
aws lambda invoke \
  --function-name oracle-ebs-scaler \
  --cli-binary-format raw-in-base64-out \
  --payload '{"action": "scale_up", "volume_id": "vol-0663e1160ec359efa"}' \
  /dev/stdout
```
