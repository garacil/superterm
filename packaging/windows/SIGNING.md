# How to sign and publish the Windows release

From nothing to four signed assets on GitHub. `README.md` in this directory is
the reference for how the release script works; this file is the procedure.

Signing is what removes SmartScreen's "Windows protected your PC", the browser's
download warning, the "Unknown publisher" prompt, and — in practice — Defender's
`Trojan:Win32/Wacatac.B!ml` verdict on a freshly published installer. The
publisher Windows names is the certificate's subject, so it is the certificate,
not anything in the code, that decides what users see.

## Where this project stands

**The first signed release went out on 2026-09-09.** `superterm.exe`,
`superterm-tray.exe`, the installer and its uninstaller all verify as `Valid`
under `CN="7kas Servicios Internet, S.L."`, and the v5.2.2 assets on GitHub are
those. Nothing in **Part 1** has to be done again until the identity validation
expires on **2028-12-07**.

| | |
|---|---|
| Subscription | **7Kas** `5537b9cc-c817-41cf-b4b9-29f406ace60d` |
| Tenant | 7kas.com `e91cd423-a399-472b-9d02-86368d44d9aa` |
| Signing account | **`signing-7kas`**, resource group `signing-7kas`, West Europe, SKU Basic |
| Certificate profile | **`public-7kas`**, public trust, active |
| Identity validation | `a33951cd-d91f-4269-9404-1049b4d8d853`, completed, expires 2028-12-07 |
| Certificate subject | `CN=7kas Servicios Internet, S.L., O=7kas Servicios Internet, S.L., L=Benicasim, S=Castellón, C=ES` |
| Endpoint | `https://weu.codesigning.azure.net` |

`trusted-signing.json` already carries the endpoint, the account and the
profile. **Start at Part 2.**

### There is no private key to keep

Worth being explicit, because it inverts the habit of every other code-signing
certificate: **Microsoft never hands over a key.** The private key is generated
and used inside their HSM and never leaves it. There is no `.pfx` on this
machine, no token in a drawer, no secret in the repository, and nothing to back
up or to lose.

Recreating this on another PC therefore needs three things, none of them
confidential:

1. **`trusted-signing.json`**, in this directory and committed — endpoint,
   account name, profile name, and nothing else.
2. The two tools from **Part 2**, both public downloads.
3. An Azure login for a principal holding **Artifact Signing Certificate Profile
   Signer** on the `signing-7kas` account.

If this machine dies, nothing is lost but the twenty minutes of Part 2.

## Part 1 — Azure, once per organisation

Skip this unless the validation has expired or the publisher changes.

Microsoft renamed *Trusted Signing* to **Artifact Signing**; the portal, and the
RBAC roles, use the new name, while the NuGet package, the dlib and the
`codesigning.azure.net` endpoint keep the old one. Searching the portal for
"Trusted" finds nothing.

1. **Sign in with a work account.** A personal Microsoft account lands in a
   tenant with no subscriptions; the company one may need the *directory*
   switched rather than the account. Artifact Signing needs a pay-as-you-go
   subscription — the free trial credit does not cover it.
2. **Create the Artifact Signing account.** Basic, about US$10/month, is right:
   the tiers differ in how many profiles and signatures they allow, not in what
   they can do. Pick the region whose endpoint you will put in
   `trusted-signing.json` — West Europe is `weu.codesigning.azure.net`.
3. **Accept the terms of use** from the banner on the identity validation blade.
   They are a contract with the company; whoever accepts warrants they can bind
   it.
4. **Assign both roles** on the account, under Control de acceso (IAM). Owner on
   the subscription grants neither, and the blade stays greyed out without them:
   - **Artifact Signing Identity Verifier** — without it, "Create identity
     validation" is disabled.
   - **Artifact Signing Certificate Profile Signer** — what the build machine
     needs. Assign it now; forgotten, it surfaces as an obscure failure during
     the first signed build.

   The wizard only assigns when it reaches *Revisar y asignar*; stopping at the
   Miembros tab silently does nothing. Confirm the resource's role list shows
   both before blaming propagation, which takes a few minutes.
5. **Create an Identity Validation of type Público.** Privado issues
   certificates trusted only inside your own organisation. Organisation
   validation wants a legal entity with three or more years of verifiable
   history. A Spanish company identifies itself by CIF under *Identificación
   fiscal*, not by the DUNS number the field defaults to. The country list is in
   English whatever the portal's language.

   Read the **certificate signer preview** at the foot of the form before
   submitting. Its `CN` is what Windows will display as the publisher, and it
   must equal `CompanyName` in `src/superterm.rc` and `AppPublisher` in
   `superterm.iss`. A wrong field here means revalidating from scratch.

   Then wait. It ran three business days for 7kas. Microsoft may verify by mail
   to the contact addresses or by telephone, so use addresses that will still
   receive mail.
6. **Create the Certificate Profile.** The Crear menu puts *Confianza pública*
   and *Prueba de confianza pública* next to each other and only the first is
   trusted by Windows. Leave *Incluir dirección postal* and *Incluir código
   postal* unchecked: they write the company's street address into a certificate
   that ships inside every published binary, and buy no trust.
7. **Fill `trusted-signing.json`** with the endpoint, account and profile names.

## Part 2 — the build machine, once per machine

Three things, none of which come with Windows.

**A `signtool` from Windows SDK 10.0.22621 or newer.** `/dlib` did not exist
before that, and this is the step that catches people out: a machine can carry
several signtools and all of them be too old. `sign.ps1` picks the newest
versioned one under the Windows Kits, which will still be too old. Look first:

```powershell
Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kits\10\bin" -Filter signtool.exe -Recurse |
  Where-Object FullName -like '*x64*' |
  ForEach-Object { '{0} -> {1}' -f $_.FullName, $_.VersionInfo.ProductVersion }
```

**`Azure.CodeSigning.Dlib.dll`**, from the `Microsoft.Trusted.Signing.Client`
NuGet package.

**An Azure login.** The dlib authenticates through `DefaultAzureCredential` by
itself, and without credentials it fails inside the dlib rather than in
`sign.ps1`, naming the account instead of the login.

A `.nupkg` is a zip, so no package manager is needed. `Microsoft.Windows.SDK.BuildTools`
brings a current signtool along, under `sdk\bin\<version>\x64`:

```powershell
mkdir C:\tools\signing; cd C:\tools\signing
Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Trusted.Signing.Client' -OutFile dlib.zip
Invoke-WebRequest 'https://www.nuget.org/api/v2/package/Microsoft.Windows.SDK.BuildTools' -OutFile sdk.zip
Expand-Archive dlib.zip -DestinationPath dlib -Force
Expand-Archive sdk.zip -DestinationPath sdk -Force
winget install --id Microsoft.AzureCLI -e
```

## Part 3 — the signed release

These are the paths the 2026-09-09 release actually used, with the signtool that
came out of the package at 10.0.28000. Give `SUPERTERM_SIGN_METADATA` an
absolute path: it is handed down to `signtool` through Inno Setup, which does not
run from the repository root.

```powershell
az login
$env:SUPERTERM_SIGNTOOL      = 'C:\tools\signing\sdk\bin\10.0.28000.0\x64\signtool.exe'
$env:SUPERTERM_SIGN_DLIB     = 'C:\tools\signing\dlib\bin\x64\Azure.CodeSigning.Dlib.dll'
$env:SUPERTERM_SIGN_METADATA = 'D:\sources\superterm\packaging\windows\trusted-signing.json'
powershell -ExecutionPolicy Bypass -File packaging\windows\release.ps1 -Sign -Upload -Replace
```

`az` may not be on the PATH of a shell that was open when it was installed;
`C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin` is where it lands. Check the
session is the right one before signing — `az account show` should name the
7Kas subscription and the tenant `e91cd423-a399-472b-9d02-86368d44d9aa`.

In CI the login becomes `AZURE_TENANT_ID`, `AZURE_CLIENT_ID` and
`AZURE_CLIENT_SECRET`, which `DefaultAzureCredential` reads on its own.

Nothing in `src/superterm.rc` or `superterm.iss` has to be configured for this.
`-Sign` signs `superterm.exe` and `superterm-tray.exe`, then hands ISCC `/DSIGN`
and a `/Ssuperterm=` hook, which turns on `SignTool=superterm` and
`SignedUninstaller=yes` inside the script's `#ifdef SIGN` and makes Inno call
`sign.ps1` for the setup and the uninstaller. `[Files]` entries carry `signonce`
so nothing is signed twice. `release.ps1` verifies every signature afterwards
and stops if one is not valid, and `sign.ps1` refuses to run at all when no
certificate is configured — a `-Sign` release cannot come out unsigned by
accident.

**Why `-Replace`.** v5.2.2 is already published, and signing changes the bytes
without changing the version, so the upload's immutability guard would refuse
it. That guard is right and `-Replace` is the exception: once a download URL has
gone into a Microsoft Store submission, a new binary means a new `VERSION`
instead. See "A published URL keeps its bytes" in `README.md`.

Signing one file by hand:

```powershell
powershell -ExecutionPolicy Bypass -File packaging\windows\sign.ps1 bin\superterm.exe
```

## Two things that look wrong and are not

**The certificate expires in about seventy-two hours.** Artifact Signing issues
short-lived certificates and rotates them per signature; there is nothing to
renew and nothing to install. An installer signed today stays valid for years
because of the **RFC 3161 timestamp** `sign.ps1` always adds, which attests the
signature was made while the certificate was current. What expires meaningfully
is the identity validation, in 2028.

**Defender may still flag a brand-new installer.** Signing removes the publisher
warnings immediately and collapses the ML false positives, but reputation
accrues per publisher over downloads. If `Trojan:Win32/Wacatac.B!ml` or similar
appears, submit the file at <https://www.microsoft.com/en-us/wdsi/filesubmission>
as a **software developer**, marked a false positive, with the repository URL.
Analysts clear it within a day or two — but per file hash, so the durable fix
remains the signature.
