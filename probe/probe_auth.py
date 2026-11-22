#!/usr/bin/env python3
"""Stage 1: can this account get a CryptAuth-scoped token at all?

This is gate #1. If Google won't issue the `cryptauth` scope to a device-auth
sign-in, the whole Phone-Hub-on-Mac idea stops here and you never need stage 2.

Nothing is sent to CryptAuth yet. This only does Google device auth (the same
flow microG uses) and asks for the cryptauth scope.

Use a THROWAWAY Google account.

Setup:
    pip install -r requirements.txt

Getting a master token (once per account):
    1. Open the account's OAuth token page in a browser you can sign in with:
       https://accounts.google.com/EmbeddedSetup
       Sign in, approve, then copy the `oauth_token` cookie value (starts "oauth2_4/").
    2. Run:  ./probe_auth.py mastertoken <email> <oauth_token>
       It prints a master token (starts "aas_et/"). Save it.

Then test the scope:
    ./probe_auth.py cryptauth <email> <master_token>

Reading the result:
    - prints an auth token  -> gate #1 PASSED, go to stage 2
    - "needs browser" / 403 -> gate #1 FAILED, stop
"""
import sys
import uuid

import gpsoauth

# Android device identity for gpsoauth. Any 16 hex digits; Google binds the
# master token to it. Stable per account, so derived from a fixed random value.
ANDROID_ID = "3812d1b8e3a0c4f9"

GMS_PACKAGE = "com.google.android.gms"
GMS_SIG = "38918a453d07199354f8b19af05ec6562ced5788"
CRYPTAUTH_SCOPE = "oauth2:https://www.googleapis.com/auth/cryptauth"


def cmd_mastertoken(email: str, oauth_token: str) -> None:
    res = gpsoauth.exchange_token(email, oauth_token, ANDROID_ID)
    token = res.get("Token")
    if token:
        print("master token:", token)
        print("save this; use it with the cryptauth command")
    else:
        print("FAILED to get master token")
        print(res)


def cmd_cryptauth(email: str, master_token: str) -> None:
    res = gpsoauth.perform_oauth(
        email,
        master_token,
        ANDROID_ID,
        service=CRYPTAUTH_SCOPE,
        app=GMS_PACKAGE,
        client_sig=GMS_SIG,
    )
    token = res.get("Auth")
    print("-- raw response --")
    print(res)
    print()
    if token:
        print("GATE 1 PASSED: cryptauth token issued")
        print("auth token:", token)
        print()
        print("next: ./probe_enroll.py", email, "<master_token>")
    else:
        print("GATE 1 FAILED: no cryptauth token")
        print("look at the response above. A scope/permission error here means")
        print("this account's device-auth path is not allowed the cryptauth scope.")


def main() -> None:
    args = sys.argv[1:]
    if len(args) == 3 and args[0] == "mastertoken":
        cmd_mastertoken(args[1], args[2])
    elif len(args) == 3 and args[0] == "cryptauth":
        cmd_cryptauth(args[1], args[2])
    else:
        print(__doc__)
        sys.exit(1)


if __name__ == "__main__":
    main()
