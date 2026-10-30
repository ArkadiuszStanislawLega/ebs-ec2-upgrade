import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from botocore.stub import ANY, Stubber

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
import scaler  # noqa: E402

VOL_DATA = "vol-01111111111111111"
VOL_REDO = "vol-02222222222222222"

MOCK_VOLUMES_CONFIG = {
    VOL_DATA: {
        "alarm_name": f"ebs-oracle-throughput-saturation-{VOL_DATA}",
        "base_throughput": 125,
        "high_throughput": 1000,
        "base_iops": 3000,
        "high_iops": 4000,
        "scale_down_threshold_mbps": 85.0,
        "min_minutes_before_scaledown": 60.0,
        "lookback_minutes": 60,
    },
    VOL_REDO: {
        "alarm_name": f"ebs-oracle-throughput-saturation-{VOL_REDO}",
        "base_throughput": 250,
        "high_throughput": 1000,
        "base_iops": 6000,
        "high_iops": 6000,
        "scale_down_threshold_mbps": 150.0,
        "min_minutes_before_scaledown": 60.0,
        "lookback_minutes": 60,
    },
}


@pytest.fixture(autouse=True)
def setup_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("VOLUMES_CONFIG_JSON", json.dumps(MOCK_VOLUMES_CONFIG))


def test_scale_up_from_sns_metric_math_payload() -> None:
    sns_alarm_payload = {
        "AlarmName": f"ebs-oracle-throughput-saturation-{VOL_DATA}",
        "NewStateValue": "ALARM",
        "Trigger": {
            "Metrics": [
                {
                    "Id": "m_read",
                    "MetricStat": {
                        "Metric": {
                            "Namespace": "AWS/EBS",
                            "MetricName": "VolumeReadBytes",
                            "Dimensions": [{"name": "VolumeId", "value": VOL_DATA}],
                        },
                        "Period": 60,
                        "Stat": "Sum",
                    },
                    "ReturnData": False,
                }
            ]
        },
    }
    sns_event = {
        "Records": [
            {
                "EventSource": "aws:sns",
                "Sns": {"Message": json.dumps(sns_alarm_payload)},
            }
        ]
    }

    with Stubber(scaler.ec2_client) as ec2_stub:
        ec2_stub.add_response(
            "describe_volumes",
            {"Volumes": [{"VolumeId": VOL_DATA, "Throughput": 125, "Iops": 3000}]},
            {"VolumeIds": [VOL_DATA]},
        )
        ec2_stub.add_client_error(
            "describe_volumes_modifications",
            service_error_code="InvalidVolumeModification.NotFound",
            service_message="Not found",
            expected_params={"VolumeIds": [VOL_DATA]},
        )
        ec2_stub.add_response(
            "modify_volume",
            {"VolumeModification": {"VolumeId": VOL_DATA, "ModificationState": "modifying"}},
            {"VolumeId": VOL_DATA, "Throughput": 1000, "Iops": 4000},
        )

        result = scaler.lambda_handler(sns_event, None)
        assert result["status"] == "modified"
        assert result["volume_id"] == VOL_DATA
        assert result["throughput"] == 1000
        assert result["iops"] == 4000


def test_batch_scale_down_evaluates_all_volumes_independently() -> None:
    """VOL_DATA is idle for 75m and scales down; VOL_REDO is already at base throughput and is skipped."""
    mod_time_75m_ago = datetime.now(timezone.utc) - timedelta(minutes=75)

    with Stubber(scaler.ec2_client) as ec2_stub, Stubber(scaler.cw_client) as cw_stub:
        # 1. Calls for VOL_DATA (currently at 1000 MB/s -> should scale down to 125 MB/s)
        ec2_stub.add_response(
            "describe_volumes",
            {"Volumes": [{"VolumeId": VOL_DATA, "Throughput": 1000, "Iops": 4000}]},
            {"VolumeIds": [VOL_DATA]},
        )
        ec2_stub.add_response(
            "describe_volumes_modifications",
            {
                "VolumesModifications": [
                    {"VolumeId": VOL_DATA, "ModificationState": "completed", "StartTime": mod_time_75m_ago}
                ]
            },
            {"VolumeIds": [VOL_DATA]},
        )
        cw_stub.add_response(
            "describe_alarms",
            {"MetricAlarms": [{"AlarmName": MOCK_VOLUMES_CONFIG[VOL_DATA]["alarm_name"], "StateValue": "OK"}]},
            {"AlarmNames": [MOCK_VOLUMES_CONFIG[VOL_DATA]["alarm_name"]]},
        )
        cw_stub.add_response(
            "get_metric_data",
            {"MetricDataResults": [{"Id": "throughput_mbps", "Values": [12.0, 35.5]}]},
            {"MetricDataQueries": ANY, "StartTime": ANY, "EndTime": ANY},
        )
        ec2_stub.add_response(
            "modify_volume",
            {"VolumeModification": {"VolumeId": VOL_DATA, "ModificationState": "modifying"}},
            {"VolumeId": VOL_DATA, "Throughput": 125, "Iops": 3000},
        )

        # 2. Calls for VOL_REDO (currently at base 250 MB/s -> should skip immediately)
        ec2_stub.add_response(
            "describe_volumes",
            {"Volumes": [{"VolumeId": VOL_REDO, "Throughput": 250, "Iops": 6000}]},
            {"VolumeIds": [VOL_REDO]},
        )

        batch_result = scaler.lambda_handler({"action": "scale_down"}, None)
        assert batch_result["status"] == "batch_completed"
        assert batch_result["results"][VOL_DATA]["status"] == "modified"
        assert batch_result["results"][VOL_DATA]["throughput"] == 125
        assert batch_result["results"][VOL_REDO]["status"] == "skipped"
        assert batch_result["results"][VOL_REDO]["reason"] == "already_at_base_throughput"
