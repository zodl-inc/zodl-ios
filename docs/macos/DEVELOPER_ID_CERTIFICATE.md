# Creating the Developer ID Application certificate (ZODL macOS)

We need a **Developer ID Application** certificate to sign the ZODL macOS app for
distribution **outside** the Mac App Store (notarized DMG). Apple gates the creation
of this certificate type to the **Account Holder** of the developer team — Admins
cannot create it, and it cannot be created via the App Store Connect API or fastlane.
It is a one-time, ~3-minute action.

- Team: **RLPRR8CPQG**
- Certificate type: **Developer ID Application** (G2 Sub-CA)
- Who does what: the developer prepares a CSR (Part 1), the **Account Holder** does
  the portal steps (Part 2), the developer finishes locally (Part 3).

The flow below is designed so that **no private key ever travels between people** —
the key is generated on the build Mac and never leaves it. The files that are
exchanged (`.certSigningRequest`, `.cer`) contain no secrets and can be sent over
normal channels.

---

## Part 1 — Developer, on the build Mac (before contacting the Account Holder)

1. Open **Keychain Access**.
2. Menu bar: **Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority…**
3. Fill in:
   - **User Email Address:** your email
   - **Common Name:** e.g. `ZODL Developer ID` (this becomes the private key's name in
     your keychain)
   - **CA Email Address:** leave empty
   - Select **"Saved to disk"** (leave "Let me specify key pair information" unchecked —
     the default RSA 2048 is correct)
4. Save the resulting `CertificateSigningRequest.certSigningRequest` and send this file
   to the Account Holder.

## Part 2 — Account Holder, in the developer portal (~3 minutes)

> You must be signed in as the **Account Holder** of team **RLPRR8CPQG** — Admins don't
> see this certificate type. Everything happens on developer.apple.com, not
> App Store Connect.

1. Sign in at <https://developer.apple.com/account>
2. Go to **Certificates, Identifiers & Profiles → Certificates**
   (direct link: <https://developer.apple.com/account/resources/certificates/list>)
3. Click the **＋** button next to "Certificates".
4. In the list, under the **Software / Developer ID** section, select
   **Developer ID Application** ("This certificate is used to code sign your app for
   distribution outside of the Mac App Store") → **Continue**.
5. If asked for a **Profile Type**, choose **G2 Sub-CA (Xcode 11.4.1 or later)** —
   we build with a current Xcode.
6. **Choose File** → upload the `CertificateSigningRequest.certSigningRequest` file
   received in Part 1 → **Continue**.
7. **Download** the generated certificate (`developerID_application.cer`).
8. Send the `.cer` file back to the developer (it contains no private key — plain
   email/Slack is fine).

That is everything the Account Holder needs to do.

> **Please do not substitute the "grant cloud-managed Developer ID access" option.**
> Cloud-managed Developer ID certificates only work inside Xcode's GUI and cannot be
> used by our automated (fastlane / headless `xcodebuild`) release builds. We need
> this classic certificate.

## Part 3 — Developer, back on the build Mac

1. Double-click the received `.cer` **on the same Mac and user account where the CSR
   was created** — Keychain Access pairs it with the waiting private key automatically
   (it should land in the **login** keychain).
2. Verify it is usable:

   ```bash
   security find-identity -v -p codesigning
   ```

   You should see a valid identity like
   `Developer ID Application: <company name> (RLPRR8CPQG)`.
3. **Back it up immediately:** in Keychain Access, right-click the certificate (expand
   it so the private key is included) → **Export** → save as a password-protected
   `.p12` → store the file and password in the team's secrets vault.

   Why this matters:
   - the team can hold at most **5** Developer ID Application certificates,
   - the certificate is valid for **5 years**,
   - CI machines will need this `.p12`,
   - it **cannot** be re-downloaded from Apple later — Apple never has the private key.

---

## Notes for the Account Holder

- This is **not** a per-app or per-release action — one Developer ID Application
  certificate covers all of the team's out-of-store Mac software for 5 years.
- We do **not** need a "Developer ID **Installer**" certificate (that type is only for
  `.pkg` installers distributed outside the store; we ship a DMG). If you want to
  create one in the same sitting for future-proofing, the flow is identical and the
  same CSR file can be reused — but it's optional.

## Alternative: Account Holder does everything solo

If preferred, the Account Holder can run Part 1 themselves on their own Mac, then
after downloading the certificate in Part 2, export the certificate **together with
the private key** from Keychain Access as a password-protected `.p12` and hand that
to the developer over a **secure** channel (send the password separately). The
CSR-exchange flow above is preferred, since no key material ever moves.
