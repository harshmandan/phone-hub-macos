# enrollKeys: the real device-key enrollment

What turns "the server accepts a CHROME identity" (gate 2) into "the phone lists
the Mac" (gate 3). Implemented in `probe/enroll_keys.py`.

## The call

`v1:enrollKeys` with:

```
randomSessionId:          the session string from syncKeys
enrollSingleKeyRequests:  [ one request for the "PublicKey" device key ]
```

No `clientEphemeralDh`. That field is only for creating symmetric keys, which
need a Diffie-Hellman secret. Our device key is P256 (asymmetric), so there is
none — which is also why syncKeys returned no `server_ephemeral_dh`.

## The single request

| Field | Value |
| --- | --- |
| `keyName` | `PublicKey` |
| `newKeyHandle` | `device_key` (the fixed user-key-pair handle) |
| `keyMaterial` | the new P256 public key, as a securemessage `GenericPublicKey` |
| `keyProof` | proof of possession (below) |

### keyMaterial encoding

Chrome does not send raw DER. It sends a `GenericPublicKey` proto:

```
GenericPublicKey { type = EC_P256; ec_p256_public_key = { x; y } }
```

`x` and `y` are the curve coordinates in Java `BigInteger.toByteArray()` form:
big-endian, and a leading `0x00` when the top bit is set (so they stay
positive). This is the detail most likely to need a tweak if the server rejects
`key_material`.

### keyProof

Proof that we hold the private key for the key we are enrolling:

```
ECDSA-SHA256( newPrivateKey, "CryptAuth Key Proof" + sessionBytes )   # DER signature
```

`sessionBytes` is the base64-decoded `randomSessionId`. Salt constant is from
`cryptauth_enrollment_constants.cc`.

## Source

- `cryptauth_v2_enroller_impl.cc` — request shape, `OnKeysCreated`
- `cryptauth_key_proof_computer_impl.cc` — `ComputeAsymmetricKeyProof`
- `cryptauth_key_creator_impl.cc` — P256 vs symmetric, when DH is needed
- `cryptauth_enrollment.proto` — field names

## Status

Built and unit-checked (structure, signature, encoding). Not yet run against the
server — that needs the throwaway account. A 200 from enrollKeys, then the Mac
appearing on the phone, closes gate 3.
