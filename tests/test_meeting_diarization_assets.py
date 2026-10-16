"""Local-only dynamic assets; fake bytes never certify a model."""

import hashlib
import json

from speechrail.service.diarization_assets import (
    inspect_meeting_dynamic_assets,
    prepare_meeting_dynamic_assets,
)


def test_missing_bundle_is_not_ready_and_does_not_access_network(tmp_path, monkeypatch):
    import httpx

    def forbidden(*args, **kwargs):
        raise AssertionError("preflight must be local")

    monkeypatch.setattr(httpx.Client, "send", forbidden)
    assert not inspect_meeting_dynamic_assets(tmp_path)


def test_fake_staging_is_verified_and_existing_bundle_preserved(tmp_path):
    data = json.dumps({"tensors": {"psi": {"data_base64": "AACAPw=="}}}).encode()
    files = {"plda-parameters.json": (len(data), hashlib.sha256(data).hexdigest())}
    def fetch(path):
        return iter([data])
    root = prepare_meeting_dynamic_assets(tmp_path, fetch=fetch, files=files)
    assert inspect_meeting_dynamic_assets(root, files=files)
    (root / "plda-parameters.json").write_bytes(b"invalid")
    assert not inspect_meeting_dynamic_assets(root, files=files)
    import pytest

    with pytest.raises(RuntimeError):
        prepare_meeting_dynamic_assets(tmp_path, fetch=fetch, files=files)
    assert (root / "plda-parameters.json").read_bytes() == b"invalid"
