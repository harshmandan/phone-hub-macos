#!/usr/bin/env python3
"""Shared helpers for the probe scripts — the CryptAuth token, device-key loading,
and the DeviceSync/CryptAuth HTTP POST that were copy-pasted across several files.
"""
import json
import urllib.request

import gpsoauth

from probe_auth import ANDROID_ID, GMS_PACKAGE, GMS_SIG, CRYPTAUTH_SCOPE
from probe_enroll import API_KEY, ANDROID_CERT


def cryptauth_token(email: str, master: str) -> str | None:
    """Device-auth OAuth for the cryptauth scope; returns the Auth token or None."""
    return gpsoauth.perform_oauth(
        email, master, ANDROID_ID,
        service=CRYPTAUTH_SCOPE, app=GMS_PACKAGE, client_sig=GMS_SIG,
    ).get("Auth")


def load_keys(path: str = "device_keys.json") -> dict:
    """Load the enrolled device identity + keys saved by probe_enroll.py."""
    with open(path) as f:
        return json.load(f)


def post(url: str, auth_token: str, body: dict) -> tuple[int, str]:
    """POST a JSON body to a CryptAuth/DeviceSync endpoint with the GMS headers."""
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(),
        headers={
            "x-goog-api-key": API_KEY,
            "x-android-package": GMS_PACKAGE,
            "x-android-cert": ANDROID_CERT,
            "Authorization": f"Bearer {auth_token}",
            "Content-Type": "application/json",
        }, method="POST")
    try:
        r = urllib.request.urlopen(req)
        return r.getcode(), r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
