import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Dict, List

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ec2_client = boto3.client("ec2")
cw_client = boto3.client("cloudwatch")

RATE_LIMIT_ERROR_CODES = {
    "VolumeModificationRateExceeded",
    "IncorrectModificationState",
}


def get_config() -> Dict[str, Any]:
    return {
        "volume_id": os.environ["VOLUME_ID"],
        "alarm_name": os.environ["ALARM_NAME"],
        "base_throughput": int(os.environ.get("BASE_THROUGHPUT", "125")),
        "high_throughput": int(os.environ.get("HIGH_THROUGHPUT", "1000")),
        "base_iops": int(os.environ.get("BASE_IOPS", "3000")),
        "high_iops": int(os.environ.get("HIGH_IOPS", "4000")),
        "scale_down_threshold_mbps": float(os.environ.get("SCALE_DOWN_THRESHOLD_MBPS", "85.0")),
        "min_minutes_before_scaledown": float(os.environ.get("MIN_MINUTES_BEFORE_SCALEDOWN", "60.0")),
        "lookback_minutes": int(os.environ.get("LOOKBACK_MINUTES", "60")),
    }


def log_event(level: int, event_type: str, **kwargs: Any) -> None:
    payload = {"event": event_type, **kwargs}
    logger.log(level, json.dumps(payload))


def get_volume_state(volume_id: str) -> Dict[str, Any]:
    response = ec2_client.describe_volumes(VolumeIds=[volume_id])
    volumes = response.get("Volumes", [])
    if not volumes:
        raise RuntimeError(f"Target EBS volume {volume_id} does not exist.")
    return volumes[0]


def fetch_volume_modifications(volume_id: str) -> List[Dict[str, Any]]:
    try:
        response = ec2_client.describe_volumes_modifications(VolumeIds=[volume_id])
        return response.get("VolumesModifications", [])
    except ClientError as err:
        if err.response.get("Error", {}).get("Code") == "InvalidVolumeModification.NotFound":
            return []
        raise


def get_modification_status(volume_id: str) -> Dict[str, Any]:
    modifications = fetch_volume_modifications(volume_id)
    if not modifications:
        return {"state": "none", "minutes_elapsed": 99999.0}

    latest_mod = sorted(modifications, key=lambda x: x["StartTime"], reverse=True)[0]
    elapsed = datetime.now(timezone.utc) - latest_mod["StartTime"]
    return {
        "state": latest_mod["ModificationState"],
        "minutes_elapsed": max(0.0, elapsed.total_seconds() / 60.0),
    }


def is_alarm_in_ok_state(alarm_name: str) -> bool:
    response = cw_client.describe_alarms(AlarmNames=[alarm_name])
    alarms = response.get("MetricAlarms", [])
    if not alarms:
        return True
    return alarms[0]["StateValue"] == "OK"


def get_max_throughput_mbps(volume_id: str, minutes: int) -> float:
    end_time = datetime.now(timezone.utc)
    start_time = end_time - timedelta(minutes=minutes)

    response = cw_client.get_metric_data(
        MetricDataQueries=[
            {
                "Id": "read_bytes",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/EBS",
                        "MetricName": "VolumeReadBytes",
                        "Dimensions": [{"Name": "VolumeId", "Value": volume_id}],
                    },
                    "Period": 60,
                    "Stat": "Sum",
                },
                "ReturnData": False,
            },
            {
                "Id": "write_bytes",
                "MetricStat": {
                    "Metric": {
                        "Namespace": "AWS/EBS",
                        "MetricName": "VolumeWriteBytes",
                        "Dimensions": [{"Name": "VolumeId", "Value": volume_id}],
                    },
                    "Period": 60,
                    "Stat": "Sum",
                },
                "ReturnData": False,
            },
            {
                "Id": "throughput_mbps",
                "Expression": "(read_bytes + write_bytes) / PERIOD(read_bytes) / 1048576",
                "Label": "ThroughputMBps",
                "ReturnData": True,
            },
        ],
        StartTime=start_time,
        EndTime=end_time,
    )

    results = response.get("MetricDataResults", [])
    if not results or not results[0].get("Values"):
        return 0.0
    return float(max(results[0]["Values"]))


def modify_ebs(volume_id: str, throughput: int, iops: int, direction: str) -> Dict[str, Any]:
    try:
        ec2_client.modify_volume(
            VolumeId=volume_id,
            Throughput=throughput,
            Iops=iops,
        )
        log_event(
            logging.INFO,
            "ebs_modified",
            direction=direction,
            volume_id=volume_id,
            target_throughput_mbps=throughput,
            target_iops=iops,
        )
        return {
            "status": "modified",
            "direction": direction,
            "volume_id": volume_id,
            "throughput": throughput,
            "iops": iops,
        }
    except ClientError as err:
        error_code = err.response.get("Error", {}).get("Code", "")
        if error_code in RATE_LIMIT_ERROR_CODES:
            level = logging.ERROR if direction == "scale_up" else logging.INFO
            log_event(
                level,
                "ebs_modify_deferred",
                direction=direction,
                volume_id=volume_id,
                aws_error_code=error_code,
            )
            return {"status": "deferred_by_aws_rate_limit", "aws_error_code": error_code}
        log_event(
            logging.ERROR,
            "ebs_modify_failed",
            direction=direction,
            volume_id=volume_id,
            error=str(err),
        )
        raise


def handle_scale_up(cfg: Dict[str, Any]) -> Dict[str, Any]:
    vol_id = cfg["volume_id"]
    vol = get_volume_state(vol_id)
    current_tp = vol.get("Throughput", cfg["base_throughput"])
    current_iops = vol.get("Iops", cfg["base_iops"])

    if current_tp >= cfg["high_throughput"]:
        log_event(
            logging.INFO,
            "scale_up_skipped",
            reason="already_at_high_throughput",
            volume_id=vol_id,
            current_throughput_mbps=current_tp,
        )
        return {"status": "skipped", "reason": "already_at_high_throughput"}

    mod_status = get_modification_status(vol_id)
    if mod_status["state"] == "modifying":
        log_event(
            logging.WARNING,
            "scale_up_skipped",
            reason="modification_in_progress",
            volume_id=vol_id,
        )
        return {"status": "skipped", "reason": "modification_in_progress"}

    target_iops = max(current_iops, cfg["high_iops"])
    return modify_ebs(vol_id, cfg["high_throughput"], target_iops, direction="scale_up")


def handle_scale_down(cfg: Dict[str, Any]) -> Dict[str, Any]:
    vol_id = cfg["volume_id"]
    vol = get_volume_state(vol_id)
    current_tp = vol.get("Throughput", cfg["base_throughput"])

    if current_tp <= cfg["base_throughput"]:
        log_event(
            logging.INFO,
            "scale_down_skipped",
            reason="already_at_base_throughput",
            volume_id=vol_id,
            current_throughput_mbps=current_tp,
        )
        return {"status": "skipped", "reason": "already_at_base_throughput"}

    mod_status = get_modification_status(vol_id)
    if mod_status["state"] == "modifying":
        log_event(
            logging.INFO,
            "scale_down_skipped",
            reason="modification_in_progress",
            volume_id=vol_id,
        )
        return {"status": "skipped", "reason": "modification_in_progress"}

    if mod_status["minutes_elapsed"] < cfg["min_minutes_before_scaledown"]:
        log_event(
            logging.INFO,
            "scale_down_skipped",
            reason="measurement_window_active",
            volume_id=vol_id,
            minutes_elapsed=round(mod_status["minutes_elapsed"], 1),
            required_minutes=cfg["min_minutes_before_scaledown"],
        )
        return {
            "status": "skipped",
            "reason": "measurement_window_active",
            "minutes_since_last_mod": round(mod_status["minutes_elapsed"], 1),
        }

    if not is_alarm_in_ok_state(cfg["alarm_name"]):
        log_event(
            logging.WARNING,
            "scale_down_skipped",
            reason="alarm_not_ok",
            volume_id=vol_id,
            alarm_name=cfg["alarm_name"],
        )
        return {"status": "skipped", "reason": "alarm_not_ok"}

    max_tp = get_max_throughput_mbps(vol_id, cfg["lookback_minutes"])
    if max_tp >= cfg["scale_down_threshold_mbps"]:
        log_event(
            logging.INFO,
            "scale_down_skipped",
            reason="utilization_above_threshold",
            volume_id=vol_id,
            max_mbps=round(max_tp, 2),
            threshold_mbps=cfg["scale_down_threshold_mbps"],
        )
        return {"status": "skipped", "reason": "utilization_above_threshold", "max_mbps": round(max_tp, 2)}

    return modify_ebs(vol_id, cfg["base_throughput"], cfg["base_iops"], direction="scale_down")


ACTION_DISPATCHER: Dict[str, Callable[[Dict[str, Any]], Dict[str, Any]]] = {
    "scale_up": handle_scale_up,
    "scale_down": handle_scale_down,
}


def resolve_action(event: Dict[str, Any]) -> str:
    records = event.get("Records", [])
    if records and records[0].get("EventSource") == "aws:sns":
        return "scale_up"
    return str(event.get("action", ""))


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    cfg = get_config()
    action = resolve_action(event)

    handler = ACTION_DISPATCHER.get(action)
    if not handler:
        raise ValueError(f"Unsupported action in dispatcher: '{action}'")

    return handler(cfg)
