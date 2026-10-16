"""Small serialization/provenance guards, without real datasets or PTQ."""
import json
import pytest
from export_v3_conv1_poc import packed_bytes, verified_inputs, export


def test_lane_zero_is_low_byte_and_signed_bytes_preserved():
    assert packed_bytes([-128,-1,0,1,2,3,126,127]) == [0x7F7E03020100FF80]
    assert packed_bytes(list(range(16))) == [0x0706050403020100,0x0F0E0D0C0B0A0908]


@pytest.mark.parametrize('values', [[0], [0]*7, [False]*8, [1.0]*8, [-129]*8, [128]*8])
def test_invalid_transport(values):
    with pytest.raises(ValueError):
        packed_bytes(values)


def test_reject_missing_artifact_inventory(tmp_path):
    (tmp_path/'artifact_manifest.json').write_text(json.dumps({'model_version':'v3','files':{}}))
    with pytest.raises(ValueError,match='manifest'):
        verified_inputs(tmp_path)


def test_reject_corrupt_artifact_before_loading_checkpoint(tmp_path):
    names=['qparams.json','statistics.json','weights_int8.pt','validation_metrics.json','calibration_selection_manifest.json']
    for name in names: (tmp_path/name).write_text('corrupt')
    (tmp_path/'artifact_manifest.json').write_text(json.dumps({'model_version':'v3','files':dict.fromkeys(names,'0'*64)}))
    with pytest.raises(ValueError,match='hash mismatch'):
        verified_inputs(tmp_path)


def test_existing_output_is_never_overwritten(tmp_path):
    sentinel=tmp_path/'sentinel'; sentinel.write_text('preserve')
    with pytest.raises(FileExistsError): export(tmp_path/'absent',tmp_path)
    assert sentinel.read_text()=='preserve'
