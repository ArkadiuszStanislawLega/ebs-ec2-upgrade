import json
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Dict, List, Optional

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


def load_volumes_config() -> Dict[str, Dict[str, Any]]:
    raw_json = os.environ.get("VOLUMES_CONFIG_JSON", "{}")
    configs: Dict[str, Dict[str, Any]] = json.loads(raw_json)
    if not configs:
        raise RuntimeError("VOLUMES_CONFIG_JSON environment variable is empty or not set.")
    return configs


def log_event(level: int, event_type: str, **kwargs: Any) -> None:
    logger.log(level, json.dumps({"event": event_type, **kwargs}))


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

    latest_mod = max(modifications, key=lambda x: x["StartTime"])
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
            return {
                "status": "deferred_by_aws_rate_limit",
                "volume_id": volume_id,
                "aws_error_code": error_code,
            }
        log_event(
            logging.ERROR,
            "ebs_modify_failed",
            direction=direction,
            volume_id=volume_id,
            error=str(err),
        )
        raise


def scale_up_single_volume(vol_id: str, cfg: Dict[str, Any]) -> Dict[str, Any]:
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
        return {"status": "skipped", "volume_id": vol_id, "reason": "already_at_high_throughput"}

    mod_status = get_modification_status(vol_id)
    if mod_status["state"] == "modifying":
        log_event(
            logging.WARNING,
            "scale_up_skipped",
            reason="modification_in_progress",
            volume_id=vol_id,
        )
        return {"status": "skipped", "volume_id": vol_id, "reason": "modification_in_progress"}

    target_iops = max(current_iops, int(cfg["high_iops"]))
    return modify_ebs(vol_id, int(cfg["high_throughput"]), target_iops, direction="scale_up")


def scale_down_single_volume(vol_id: str, cfg: Dict[str, Any]) -> Dict[str, Any]:
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
        return {"status": "skipped", "volume_id": vol_id, "reason": "already_at_base_throughput"}

    mod_status = get_modification_status(vol_id)
    if mod_status["state"] == "modifying":
        log_event(
            logging.INFO,
            "scale_down_skipped",
            reason="modification_in_progress",
            volume_id=vol_id,
        )
        return {"status": "skipped", "volume_id": vol_id, "reason": "modification_in_progress"}

    min_hold = float(cfg["min_minutes_before_scaledown"])
    if mod_status["minutes_elapsed"] < min_hold:
        log_event(
            logging.INFO,
            "scale_down_skipped",
            reason="measurement_window_active",
            volume_id=vol_id,
            minutes_elapsed=round(mod_status["minutes_elapsed"], 1),
            required_minutes=min_hold,
        )
        return {
            "status": "skipped",
            "volume_id": vol_id,
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
        return {"status": "skipped", "volume_id": vol_id, "reason": "alarm_not_ok"}

    max_tp = get_max_throughput_mbps(vol_id, int(cfg["lookback_minutes"]))
    threshold = float(cfg["scale_down_threshold_mbps"])
    if max_tp >= threshold:
        log_event(
            logging.INFO,
            "scale_down_skipped",
            reason="utilization_above_threshold",
            volume_id=vol_id,
            max_mbps=round(max_tp, 2),
            threshold_mbps=threshold,
        )
        return {
            "status": "skipped",
            "volume_id": vol_id,
            "reason": "utilization_above_threshold",
            "max_mbps": round(max_tp, 2),
        }

    return modify_ebs(vol_id, int(cfg["base_throughput"]), int(cfg["base_iops"]), direction="scale_down")


def extract_volume_id_from_sns(sns_message_str: str, volumes_cfg: Dict[str, Dict[str, Any]]) -> str:
    msg = json.loads(sns_message_str)
    trigger = msg.get("Trigger", {})

    for metric_item in trigger.get("Metrics", []):
        dims = metric_item.get("MetricStat", {}).get("Metric", {}).get("Dimensions", [])
        for dim in dims:
            if dim.get("name") in ("VolumeId", "volume-id") and dim.get("value") in volumes_cfg:
                return str(dim["value"])

    alarm_name = msg.get("AlarmName", "")
    for vol_id, cfg in volumes_cfg.items():
        if cfg.get("alarm_name") == alarm_name:
            return vol_id

    raise ValueError(f"Could not resolve managed volume_id from SNS alarm message: {alarm_name}")


def handle_scale_up_dispatch(
    volumes_cfg: Dict[str, Dict[str, Any]],
    target_volume_id: Optional[str],
) -> Dict[str, Any]:
    if not target_volume_id or target_volume_id not in volumes_cfg:
        raise ValueError(f"Volume '{target_volume_id}' is not registered in VOLUMES_CONFIG_JSON.")
    return scale_up_single_volume(target_volume_id, volumes_cfg[target_volume_id])


def handle_scale_down_dispatch(
    volumes_cfg: Dict[str, Dict[str, Any]],
    target_volume_id: Optional[str],
) -> Dict[str, Any]:
    if target_volume_id:
        if target_volume_id not in volumes_cfg:
            raise ValueError(f"Volume '{target_volume_id}' is not registered in VOLUMES_CONFIG_JSON.")
        return scale_down_single_volume(target_volume_id, volumes_cfg[target_volume_id])

    results: Dict[str, Any] = {}
    for vol_id, cfg in volumes_cfg.items():
        try:
            results[vol_id] = scale_down_single_volume(vol_id, cfg)
        except Exception as exc:
            log_event(logging.ERROR, "volume_scale_down_error", volume_id=vol_id, error=str(exc))
            results[vol_id] = {"status": "error", "volume_id": vol_id, "error": str(exc)}

    return {"status": "batch_completed", "results": results}


ACTION_DISPATCHER: Dict[str, Callable[[Dict[str, Dict[str, Any]], Optional[str]], Dict[str, Any]]] = {
    "scale_up": handle_scale_up_dispatch,
    "scale_down": handle_scale_down_dispatch,
}


def resolve_invocation(
    event: Dict[str, Any],
    volumes_cfg: Dict[str, Dict[str, Any]],
) -> tuple[str, Optional[str]]:
    records = event.get("Records", [])
    if records and records[0].get("EventSource") == "aws:sns":
        sns_msg = records[0].get("Sns", {}).get("Message", "{}")
        vol_id = extract_volume_id_from_sns(sns_msg, volumes_cfg)
        return "scale_up", vol_id

    action = str(event.get("action", ""))
    vol_id = event.get("volume_id")
    return action, vol_id


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    volumes_cfg = load_volumes_config()
    action, target_vol_id = resolve_invocation(event, volumes_cfg)

    handler = ACTION_DISPATCHER.get(action)
    if not handler:
        raise ValueError(f"Unsupported action in dispatcher: '{action}'")

    return handler(volumes_cfg, target_vol_id)
