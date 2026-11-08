# Offline project preparation sample

This separate development CLI reuses the preserved D3 staging/profile code.
It prepares one disposable copy for inspect → search → hash-checked edit →
guest request → inspect. The known guest check has **not run**. Production
commands remain `execution_authority_unavailable`; `run` always refuses.
The batch VM runner, guest worker and fixture initializer are excluded.

Build with full Xcode on an Apple silicon Mac:

```sh
swift build --product conduit-offline-sample --jobs 2
```

Use absent absolute destinations under a private directory you own. The source
project stays unchanged. Replace `EXPECTED_SHA256` with the `message.txt` hash
from the first manifest. `REPLACEMENT` is the absolute path to this sample's
`replacement.txt`.

```sh
.build/debug/conduit-offline-sample stage SOURCE NEW_STAGE
.build/debug/conduit-offline-sample inspect NEW_STAGE message.txt
.build/debug/conduit-offline-sample search NEW_STAGE before
.build/debug/conduit-offline-sample manifest NEW_STAGE
.build/debug/conduit-offline-sample replace NEW_STAGE message.txt EXPECTED_SHA256 REPLACEMENT
.build/debug/conduit-offline-sample inspect NEW_STAGE message.txt
.build/debug/conduit-offline-sample request NEW_STAGE sample-1
.build/debug/conduit-offline-sample export-input NEW_STAGE NEW_INPUT_PROJECT
```

Staging omits repository/dependency caches and refuses links, protected names
and unsafe paths. Edits retain the before bytes in a sibling receipt store.
This assumes exclusive ownership of the staged copy; it is not a transaction
against a hostile concurrent writer. CLI input files are bounded before reads
and cannot be links or multiply linked files.

## Observe preparation prerequisites

```sh
.build/debug/conduit-offline-sample host-capabilities
.build/debug/conduit-offline-sample host-preparation OWNED_STORAGE_DIRECTORY
```

These commands return exit 2 because observation does not admit execution.
To ask Apple's framework for restore metadata, sign a **private copy** of the
CLI with `virtualization-metadata.entitlements`. That entitlement applies only
to the copied development binary. It is neither an app grant nor filesystem or
network confinement. Never replace or sign the operator installation.

```sh
codesign --force --sign - --entitlements Samples/OfflineProject/virtualization-metadata.entitlements PRIVATE_CLI_COPY
PRIVATE_CLI_COPY prepare-latest OWNED_STORAGE_DIRECTORY NEW_PACKET
PRIVATE_CLI_COPY prepare-image OWNED_LOCAL_IPSW OWNED_STORAGE_DIRECTORY NEW_PACKET
```

`prepare-latest` contacts Apple's native catalog and uses an Apple HTTPS HEAD
request to observe image size; it downloads no restore image. Local IPSWs are
stream-hashed before/after actual framework parsing, with a 32 GiB ceiling.
Invalid storage or existing/linked packet destinations refuse before parsing
or catalog access. The packet contains only the preparation JSON, actual
hardware model bytes and a newly generated machine identifier. Treat it as a
private, machine-specific observation; it is not a pinned full guest.

The proposed conservative capacity check accounts for a 64 GiB boot-image
ceiling, 256 MiB exchange image, 8 GiB offline payload staging budget, 8 GiB
host reserve, plus the observed restore size. It is not the smallest proven
macOS disk size, a physical reservation or an enforced guest disk quota.
Missing size/compatibility data stays unknown. Adequate capacity still never
admits allocation, grants or execution in this slice.

Run the retained native controls with an absent evidence directory under an
owned private parent. The optional flag permits only the metadata observation
above. All fixtures and stdout/stderr/exit evidence remain in that directory.

```sh
python3 scripts/probe-offline-preparation.py --binary BUILT_CLI --evidence-dir NEW_EVIDENCE_DIRECTORY --observe-latest
```

A real invalid IPSW exercises Apple's parser. Other controls establish
application refusals and the staging/edit journey. They do not establish OS
confinement, a running guest, toolchain provisioning or independent review.
See `docs/qualification/m2-guest-preparation.md` for the dated outcome.
