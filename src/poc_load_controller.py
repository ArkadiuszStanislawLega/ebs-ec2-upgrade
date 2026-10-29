#!/usr/bin/env python3

import argparse
import os
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Tuple

import boto3
from botocore.exceptions import ClientError

VOLUME_ID = os.environ.get("POC_VOLUME_ID", "")
ALARM_NAME = os.environ.get("POC_ALARM_NAME", "")
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", "eu-central-1")
MOUNT_POINT = "/oradata"

ec2_client = boto3.client("ec2", region_name=AWS_REGION)
cw_client = boto3.client("cloudwatch", region_name=AWS_REGION)


def resolve_block_device(mount_point: str) -> str:
    with open("/proc/mounts", "r", encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2 and parts[1] == mount_point:
                return Path(parts[0]).resolve().name
    raise RuntimeError(f"Nie znaleziono zamontowanego urzadzenia dla {mount_point}")


def read_disk_bytes(dev_name: str) -> int:
    with open("/proc/diskstats", "r", encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 14 and parts[2] == dev_name:
                sectors_read = int(parts[5])
                sectors_written = int(parts[9])
                return (sectors_read + sectors_written) * 512
    return 0


def safe_describe_modifications(volume_id: str) -> List[Dict[str, Any]]:
    try:
        return ec2_client.describe_volumes_modifications(VolumeIds=[volume_id]).get("VolumesModifications", [])
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "InvalidVolumeModification.NotFound":
            return []
        raise


def fetch_aws_telemetry(volume_id: str, alarm_name: str) -> Tuple[int, int, str, str, str]:
    vol = ec2_client.describe_volumes(VolumeIds=[volume_id])["Volumes"][0]
    tp = vol.get("Throughput", 0)
    iops = vol.get("Iops", 0)

    mods = safe_describe_modifications(volume_id)
    mod_state = "none"
    elapsed_str = "nigdy"
    if mods:
        latest = sorted(mods, key=lambda x: x["StartTime"], reverse=True)[0]
        mod_state = latest["ModificationState"]
        elapsed_m = (datetime.now(timezone.utc) - latest["StartTime"]).total_seconds() / 60.0
        elapsed_str = f"{elapsed_m:.1f}m temu"

    alarms = cw_client.describe_alarms(AlarmNames=[alarm_name]).get("MetricAlarms", [])
    alarm_state = alarms[0]["StateValue"] if alarms else "UNKNOWN"

    return tp, iops, mod_state, elapsed_str, alarm_state


def monitor_loop(
    dev_name: str,
    total_duration_sec: int,
    fio_proc: subprocess.Popen[Any] | None = None,
) -> None:
    print(
        f"{'CZAS (UTC)':<10} | {'LOKALNE I/O':<14} | {'CW ALARM':<16} | "
        f"{'EBS TARGET':<20} | {'MOD STATE':<12} | {'OSTATNIA ZMIANA'}"
    )
    print("-" * 105)

    start_ts = time.monotonic()
    prev_bytes = read_disk_bytes(dev_name)
    prev_ts = start_ts
    fio_finished_announced = False
    scaled_up_seen = False

    try:
        while (time.monotonic() - start_ts) < total_duration_sec:
            if fio_proc and fio_proc.poll() is not None and not fio_finished_announced:
                print("-" * 105)
                print(
                    "[*] Proces fio zakonczyl prace (koniec fakturowania). "
                    "Obserwuje automatyczny powrot (Scale-Down) do 125 MB/s..."
                )
                print("-" * 105)
                fio_finished_announced = True

            time.sleep(5)
            now_ts = time.monotonic()
            curr_bytes = read_disk_bytes(dev_name)

            delta_mb = (curr_bytes - prev_bytes) / 1048576.0
            local_mbps = delta_mb / (now_ts - prev_ts)
            prev_bytes, prev_ts = curr_bytes, now_ts

            tp, iops, mod_state, elapsed_str, alarm_state = fetch_aws_telemetry(VOLUME_ID, ALARM_NAME)
            ts_str = datetime.now(timezone.utc).strftime("%H:%M:%S")

            if tp >= 1000:
                scaled_up_seen = True

            print(
                f"{ts_str:<10} | {local_mbps:>8.1f} MB/s | {alarm_state:<16} | "
                f"{tp:>4} MB/s ({iops} IOPS) | {mod_state:<12} | {elapsed_str}"
            )

            if scaled_up_seen and fio_finished_announced and tp == 125:
                print("-" * 105)
                print("[+] SUKCES E2E: Wolumen automatycznie powrocil do 125 MB/s i 3000 IOPS!")
                break
    except KeyboardInterrupt:
        print("\n[!] Przerwano przez uzytkownika.")
    finally:
        if fio_proc and fio_proc.poll() is None:
            fio_proc.terminate()
            fio_proc.wait()


def handle_burn(args: argparse.Namespace) -> None:
    dev_name = resolve_block_device(MOUNT_POINT)
    burn_sec = args.burn_minutes * 60
    total_sec = (args.burn_minutes + args.watch_minutes) * 60
    test_file = f"{MOUNT_POINT}/oracle_billing_sim.dbf"

    fio_cmd = [
        "fio",
        "--name=oracle_billing_batch",
        f"--filename={test_file}",
        "--size=10G",
        "--rw=randrw",
        "--rwmixread=70",
        "--bs=256k",
        "--direct=1",
        "--ioengine=libaio",
        "--iodepth=32",
        "--numjobs=2",
        "--group_reporting",
        "--time_based",
        f"--runtime={burn_sec}",
    ]

    print(
        f"[*] Startuje pelny cykl PoC v2: {args.burn_minutes} min obciazenia fio + "
        f"do {args.watch_minutes} min oczekiwania na Scale-Down..."
    )
    with open("/var/log/fio_poc.log", "w", encoding="utf-8") as log_file:
        fio_proc = subprocess.Popen(fio_cmd, stdout=log_file, stderr=subprocess.STDOUT)
        monitor_loop(dev_name, total_sec, fio_proc)


def handle_watch(args: argparse.Namespace) -> None:
    dev_name = resolve_block_device(MOUNT_POINT)
    monitor_loop(dev_name, args.minutes * 60, None)


DISPATCHER: Dict[str, Callable[[argparse.Namespace], None]] = {
    "burn": handle_burn,
    "watch": handle_watch,
}


def main() -> None:
    if not VOLUME_ID or not ALARM_NAME:
        raise RuntimeError(
            "Brak zmiennych srodowiskowych POC_VOLUME_ID lub POC_ALARM_NAME. "
            "Uruchom: source /etc/profile.d/poc_env.sh"
        )

    parser = argparse.ArgumentParser(description="PoC v2 EBS Auto-Throughput Load & Telemetry Controller")
    subparsers = parser.add_subparsers(dest="command", required=True)

    burn_p = subparsers.add_parser("burn", help="Uruchom pelny cykl E2E (Scale-Up pod obciazeniem + Scale-Down po ciszy)")
    burn_p.add_argument("--burn-minutes", type=int, default=4, help="Czas generowania I/O przez fio (domyslnie 4 min)")
    burn_p.add_argument(
        "--watch-minutes",
        type=int,
        default=12,
        help="Czas obserwacji na automatyczny Scale-Down po zakonczeniu fio (domyslnie 12 min)",
    )

    watch_p = subparsers.add_parser("watch", help="Obserwuj telemetrie dysku i AWS API bez generowania ruchu")
    watch_p.add_argument("--minutes", type=int, default=20, help="Czas obserwacji w minutach")

    args = parser.parse_args()
    DISPATCHER[args.command](args)


if __name__ == "__main__":
    main()
