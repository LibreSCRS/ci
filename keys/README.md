# keys/

## `rehearsal.{asc,sec.asc,env}` -- the public rehearsal key

**This key is intentionally public, secret part included. It is never
trusted by anything.** Its user ID says so:
`INSECURE rehearsal key - not LibreSCRS <rehearsal@invalid>`.

It exists so that a rehearsal runs exactly the steps a real publish runs --
signing the RPM packages, signing the repository indexes, building the
keyring packages, installing from the signed repository -- with the same code
and no special case, while the real package-signing key never leaves its
protected environment. A rehearsal that skipped signing would prove nothing
about the signing path, and a throw-away key generated per run would have to
be carried between jobs as an artefact. Committing one public key removes both
problems.

It must never appear in a published tree: the publisher accepts only the
package-signing certificate's fingerprint.

Structure, identical to the package-signing key so no script special-cases
it: an Ed25519 certification-only primary and three Ed25519 signing subkeys,
none of which expire. `rehearsal.env` names their fingerprints, in this
order, one per line:

| variable      | key                                           |
|---------------|-----------------------------------------------|
| `PACKAGE_FPR` | the primary (certification only)              |
| `S_RPM_FPR`   | the subkey that signs RPM packages            |
| `S_IDX_FPR`   | the subkey that signs repository indexes      |
| `S_REZ_FPR`   | the spare subkey (offline on the real key)    |

The key was generated once with Sequoia (`sq` 1.4.1, in the `fedora43` image
from `images.lock`, isolated `SEQUOIA_HOME`): `sq key generate --own-key
--userid '...' --expiration never --can-sign --cannot-authenticate
--cannot-encrypt --without-password`, two `sq key subkey add --can-sign
--expiration never --without-password`, and the certificate exported with
`sq cert import` + `sq cert export --cert <PACKAGE_FPR>`.

## `package-signing.{asc,env}` -- the package-signing key

The certificate of "LibreSCRS Package Signing", certified by the release
key `6B05889AC9A6A7188DF639B06F27A989C2031D16`, and its fingerprints in the
same four-line format. This is the one home of the certificate: the keyring
packages, the published `KEY.asc` and every signature check take it from
here.

The `.asc` is exported with `sq cert export`, never with `gpg --export`:
gpg rewrites the subkey binding signatures on export, and rpm 6 and `sqv`
then refuse everything signed before. The secret subkeys `S_RPM_FPR` and
`S_IDX_FPR` live only in the CI environments that sign; the primary and
`S_REZ_FPR` stay offline.
