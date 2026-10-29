import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from botocore.stub import ANY, Stubber

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "src"))
import scaler  # noqa: E402

TEST_VOL_ID = "vol-0123456789abcdef0"
TEST_ALARM_NAME = f"ebs-oracle-throughput-saturation-{TEST_VOL_ID}"


@pytest.fixture(autouse=True)
def setup_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("VOLUME_ID", TEST_VOL_ID)
    monkeypatch.setenv("ALARM_NAME", TEST_ALARM_NAME)
    monkeypatch.setenv("BASE_THROUGHPUT", "125")
    monkeypatch.setenv("HIGH_THROUGHPUT", "1000")
    monkeypatch.setenv("BASE_IOPS", "3000")
    monkeypatch.setenv("HIGH_IOPS", "4000")
    monkeypatch.setenv("SCALE_DOWN_THRESHOLD_MBPS", "85.0")
    monkeypatch.setenv("MIN_MINUTES_BEFORE_SCALEDOWN", "8.0")
    monkeypatch.setenv("LOOKBACK_MINUTES", "5")


def test_scale_up_on_fresh_volume() -> None:
    with Stubber(scaler.ec2_client) as ec2_stub:
        ec2_stub.add_response(
            "describe_volumes",
            {"Volumes": [{"VolumeId": TEST_VOL_ID, "Throughput": 125, "Iops": 3000}]},
            {"VolumeIds": [TEST_VOL_ID]},
        )
        ec2_stub.add_client_error(
            "describe_volumes_modifications",
            service_error_code="InvalidVolumeModification.NotFound",
            service_message="Not found",
            expected_params={"VolumeIds": [TEST_VOL_ID]},
        )
        ec2_stub.add_response(
            "modify_volume",
            {"VolumeModification": {"VolumeId": TEST_VOL_ID, "ModificationState": "modifying"}},
            {"VolumeId": TEST_VOL_ID, "Throughput": 1000, "Iops": 4000},
        )

        result = scaler.lambda_handler({"Records": [{"EventSource": "aws:sns"}]}, None)
        assert result["status"] == "modified"
        assert result["throughput"] == 1000
        assert result["iops"] == 4000


def test_scale_down_skipped_within_measurement_window() -> None:
    mod_time_4m_ago = datetime.now(timezone.utc) - timedelta(minutes=4)
    with Stubber(scaler.ec2_client) as ec2_stub:
        ec2_stub.add_response(
            "describe_volumes",
            {"Volumes": [{"VolumeId": TEST_VOL_ID, "Throughput": 1000, "Iops": 4000}]},
            {"VolumeIds": [TEST_VOL_ID]},
        )
        ec2_stub.add_response(
            "describe_volumes_modifications",
            {
                "VolumesModifications": [
                    {"VolumeId": TEST_VOL_ID, "ModificationState": "completed", "StartTime": mod_time_4m_ago}
                ]
            },
            {"VolumeIds": [TEST_VOL_ID]},
        )

        result = scaler.lambda_handler({"action": "scale_down"}, None)
        assert result["status"] == "skipped"
        assert result["reason"] == "measurement_window_active"


def test_scale_down_success_after_8_minutes_of_idle() -> None:
    mod_time_10m_ago = datetime.now(timezone.utc) - timedelta(minutes=10)
    with Stubber(scaler.ec2_client) as ec2_stub, Stubber(scaler.cw_client) as cw_stub:
        ec2_stub.add_response(
            "describe_volumes",
            {"Volumes": [{"VolumeId": TEST_VOL_ID, "Throughput": 1000, "Iops": 4000}]},
            {"VolumeIds": [TEST_VOL_ID]},
        )
        ec2_stub.add_response(
            "describe_volumes_modifications",
            {
                "VolumesModifications": [
                    {"VolumeId": TEST_VOL_ID, "ModificationState": "completed", "StartTime": mod_time_10m_ago}
                ]
            },
            {"VolumeIds": [TEST_VOL_ID]},
        )
        cw_stub.add_response(
            "describe_alarms",
            {"MetricAlarms": [{"AlarmName": TEST_ALARM_NAME, "StateValue": "OK"}]},
            {"AlarmNames": [TEST_ALARM_NAME]},
        )
        cw_stub.add_response(
            "get_metric_data",
            {"MetricDataResults": [{"Id": "throughput_mbps", "Values": [0.0, 12.4]}]},
            {"MetricDataQueries": ANY, "StartTime": ANY, "EndTime": ANY},
        )
        ec2_stub.add_response(
            "modify_volume",
            {"VolumeModification": {"VolumeId": TEST_VOL_ID, "ModificationState": "modifying"}},
            {"VolumeId": TEST_VOL_ID, "Throughput": 125, "Iops": 3000},
        )

        result = scaler.lambda_handler({"action": "scale_down"}, None)
        assert result["status"] == "modified"
        assert result["throughput"] == 125
        assert result["iops"] == 3000


def test_scale_down_defers_on_aws_rate_limit() -> None:
    mod_time_10m_ago = datetime.now(timezone.utc) - timedelta(minutes=10)
    with Stubber(scaler.ec2_client) as ec2_stub, Stubber(scaler.cw_client) as cw_stub:
        ec2_stub.add_response(
            "describe_volumes",
            {"Volumes": [{"VolumeId": TEST_VOL_ID, "Throughput": 1000, "Iops": 4000}]},
            {"VolumeIds": [TEST_VOL_ID]},
        )
        ec2_stub.add_response(
            "describe_volumes_modifications",
            {
                "VolumesModifications": [
                    {"VolumeId": TEST_VOL_ID, "ModificationState": "completed", "StartTime": mod_time_10m_ago}
                ]
            },
            {"VolumeIds": [TEST_VOL_ID]},
        )
        cw_stub.add_response(
            "describe_alarms",
            {"MetricAlarms": [{"AlarmName": TEST_ALARM_NAME, "StateValue": "OK"}]},
            {"AlarmNames": [TEST_ALARM_NAME]},
        )
        cw_stub.add_response(
            "get_metric_data",
            {"MetricDataResults": [{"Id": "throughput_mbps", "Values": [0.0]}]},
            {"MetricDataQueries": ANY, "StartTime": ANY, "EndTime": ANY},
        )
        ec2_stub.add_client_error(
            "modify_volume",
            service_error_code="VolumeModificationRateExceeded",
            service_message="Rate exceeded",
            expected_params={"VolumeId": TEST_VOL_ID, "Throughput": 125, "Iops": 3000},
        )

        result = scaler.lambda_handler({"action": "scale_down"}, None)
        assert result["status"] == "deferred_by_aws_rate_limit"
