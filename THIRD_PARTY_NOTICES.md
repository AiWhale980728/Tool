# Third-Party Notices

## Swift Subprocess

- Source: https://github.com/swiftlang/swift-subprocess
- Version: `1.0.0`
- Reviewed commit: `b3937ab85dd32f6e9435914599c1519074769c1a`
- License: Apache License 2.0 with Swift Runtime Library Exception
- Used in: `Sources/RelayCore/Supervisor/GitCompletionEvidenceAdapter.swift`
- Scope: the official Swift subprocess implementation provides bounded output collection, async
  cancellation, process-session isolation, graceful termination, and final process-group kill for Relay's
  fixed local evidence commands.
- Excluded: shell command construction, inherited environments, unrestricted executable discovery, and
  direct access to canonical state or human decisions.

## Swift System

- Source: https://github.com/apple/swift-system
- Version: `1.8.1` (transitive dependency of Swift Subprocess)
- Resolved commit: `869129b7bf4ecc57b97d0193ad29690ca2134750`
- License: Apache License 2.0 with Swift Runtime Library Exception
- Scope: typed file-system paths required by Swift Subprocess. Relay does not call its package product
  directly.

## pytest

- Source: https://github.com/pytest-dev/pytest
- Reviewed version: `9.1.1`
- Reviewed commit: `cf470ec0bf7eb89cd97dd56df4859eae5db46447`
- License: MIT
- Used in: `Sources/RelayCore/Supervisor/LocalPytestVerificationEvidenceAdapter.swift`
- Scope: Relay invokes the user's already-installed system Python pytest module with fixed arguments and
  consumes pytest's built-in bounded JUnit XML report. pytest and Python are not bundled or installed by
  Notch Relay.
- Excluded: third-party plugin autoload, project `addopts`, terminal-output parsing, dependency installation,
  network package resolution, and raw JUnit persistence.

## Jest

- Source: https://github.com/jestjs/jest
- Reviewed version: `30.4.2`
- Reviewed commit: `746f2a0f57c56e3bba555280f0587d40f3db95c0`
- License: MIT
- Used in: `Sources/RelayCore/Supervisor/LocalJestVerificationEvidenceAdapter.swift`
- Scope: Relay invokes the user's already-installed project-local Jest 30.4.2 CLI with fixed arguments and
  consumes Jest's built-in bounded JSON report. Jest and Node.js are not bundled or installed by Notch Relay.
- Excluded: `npx`, package installation, network package resolution, PATH-based executable discovery,
  terminal-output parsing, watch mode, cache reuse, parallel workers, and raw JSON persistence.

## cargo-nextest

- Source: https://github.com/nextest-rs/nextest
- Reviewed version: `0.9.143`
- Reviewed commit: `60fa45f638ffc3f35e74afa65737f45fcd32db2a`
- License: MIT OR Apache-2.0
- Used in: `Sources/RelayCore/Supervisor/LocalCargoNextestVerificationEvidenceAdapter.swift`
- Scope: Relay invokes the user's already-installed cargo-nextest 0.9.143 binary with fixed arguments and
  consumes its built-in bounded JUnit report. cargo-nextest, Cargo and Rust are not bundled or installed by
  Notch Relay.
- Excluded: dependency installation, online package resolution, project nextest configuration, terminal-output
  parsing, retries, parallel test execution, output persistence, and direct access to canonical state or human
  decisions.

## OpenJudge

- Source: https://github.com/agentscope-ai/OpenJudge
- Upstream tag: `v0.2.2`
- Reviewed commit: `33db7c4a19170142c14a20df32ebaeff1d8d47e4`
- Reported package version: `0.2.0` (the pinned `v0.2.2` tag retains this package version)
- License: Apache-2.0
- Used in: `Evaluation/OpenJudge/`
- Scope: the isolated offline/CI evaluation environment reuses OpenJudge's `FunctionGrader`,
  `GradingRunner`, and Accuracy/Precision/Recall analyzers for bounded Completion Review labels.
- Distribution: OpenJudge and its Python dependencies are not bundled in the macOS application.
- Excluded: Relay runtime-store reads, canonical-state or human-decision writes, raw prompt/transcript/source
  code input, model-provider execution, online dependency resolution during verification, and production quality
  claims based on the checked-in synthetic smoke fixture.

## Label Studio

- Source: https://github.com/HumanSignal/label-studio
- Reviewed version: `1.23.0`
- Reviewed release commit: `2a9bfbcbf0a844b999de97e601d16050a893f5fb`
- Official multi-architecture image digest:
  `sha256:aa461572e8f9d86a1bf9520c1db620204e86160fd2f80dd7e9d40ac84a8828ea`
- License: Apache-2.0
- Used in: `Evaluation/LabelStudio/`
- Scope: the isolated, localhost-only annotation workflow reuses Label Studio Community Edition's
  multi-user annotation UI and standard JSON export. Relay-specific code only validates consent expiry,
  independent votes, adjudication, dataset bounds, threshold approval metadata, and data-minimized export to
  OpenJudge.
- Distribution: Label Studio and its container dependencies are not bundled in the macOS application. The
  reviewed image must be pulled separately and is not installed by Notch Relay.
- Excluded: Relay runtime-store reads, canonical-state or human-decision writes, automatic task ingestion,
  public/cloud hosting, unbounded transcript/source-code imports, model-provider execution, and production
  quality claims based on checked-in synthetic annotations.

Label Studio (TM)
Copyright (c) 2019-2021 Heartex, Inc. All Rights Reserved.
Source code in the Label Studio repository is licensed under the Apache License Version 2.0. See the Apache
License terms included below.

## Perch / CodexBar

- Source: https://github.com/Richard-Yang0130/Perch
- Reviewed commit: `077050640717d7a14337376b0ee1addbb0fd9c12`
- Upstream: https://github.com/steipete/CodexBar (Perch is a UI fork and retains the CodexBar identity)
- License: MIT
- Used in: `Sources/RelayCore/AgentQuota.swift` and `Sources/RelayCore/NotchDisplayGeometry.swift`
- Scope: Codex App/CLI discovery, local app-server JSON-RPC sequencing, bounded subprocess pattern,
  sign-in failure classification, tolerant quota-response mapping, Provider separation, and multi-window
  presentation were adapted into a smaller Notch Relay implementation. Perch's inherited 66 Provider
  implementations are research input only and are not bundled.
- Excluded: OAuth token-file access, browser cookies, WebKit dashboards, remote sessions, account
  switching, PTY status scraping, provider framework, and visual assets.

MIT License

Copyright (c) 2026 Peter Steinberger

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## pytest MIT License

The MIT License (MIT)

Copyright (c) 2004 Holger Krekel and others

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
of the Software, and to permit persons to whom the Software is furnished to do
so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Jest MIT License

MIT License

Copyright (c) Meta Platforms, Inc. and affiliates.
Copyright Contributors to the Jest project.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## cargo-nextest MIT License

Copyright (c) The nextest Contributors

Permission is hereby granted, free of charge, to any
person obtaining a copy of this software and associated
documentation files (the "Software"), to deal in the
Software without restriction, including without
limitation the rights to use, copy, modify, merge,
publish, distribute, sublicense, and/or sell copies of
the Software, and to permit persons to whom the Software
is furnished to do so, subject to the following
conditions:

The above copyright notice and this permission notice
shall be included in all copies or substantial portions
of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.

## Apache License 2.0

Swift Subprocess and Swift System source headers identify those works as licensed under Apache License 2.0
with the Swift Runtime Library Exception. cargo-nextest is available under Apache License 2.0 or MIT. The
Apache License terms follow; the Swift exception is published at https://swift.org/LICENSE.txt.

                                 Apache License
                           Version 2.0, January 2004
                        http://www.apache.org/licenses/

   TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION

   1. Definitions.

      "License" shall mean the terms and conditions for use, reproduction,
      and distribution as defined by Sections 1 through 9 of this document.

      "Licensor" shall mean the copyright owner or entity authorized by
      the copyright owner that is granting the License.

      "Legal Entity" shall mean the union of the acting entity and all
      other entities that control, are controlled by, or are under common
      control with that entity. For the purposes of this definition,
      "control" means (i) the power, direct or indirect, to cause the
      direction or management of such entity, whether by contract or
      otherwise, or (ii) ownership of fifty percent (50%) or more of the
      outstanding shares, or (iii) beneficial ownership of such entity.

      "You" (or "Your") shall mean an individual or Legal Entity
      exercising permissions granted by this License.

      "Source" form shall mean the preferred form for making modifications,
      including but not limited to software source code, documentation
      source, and configuration files.

      "Object" form shall mean any form resulting from mechanical
      transformation or translation of a Source form, including but
      not limited to compiled object code, generated documentation,
      and conversions to other media types.

      "Work" shall mean the work of authorship, whether in Source or
      Object form, made available under the License, as indicated by a
      copyright notice that is included in or attached to the work
      (an example is provided in the Appendix below).

      "Derivative Works" shall mean any work, whether in Source or Object
      form, that is based on (or derived from) the Work and for which the
      editorial revisions, annotations, elaborations, or other modifications
      represent, as a whole, an original work of authorship. For the purposes
      of this License, Derivative Works shall not include works that remain
      separable from, or merely link (or bind by name) to the interfaces of,
      the Work and Derivative Works thereof.

      "Contribution" shall mean any work of authorship, including
      the original version of the Work and any modifications or additions
      to that Work or Derivative Works thereof, that is intentionally
      submitted to Licensor for inclusion in the Work by the copyright owner
      or by an individual or Legal Entity authorized to submit on behalf of
      the copyright owner. For the purposes of this definition, "submitted"
      means any form of electronic, verbal, or written communication sent
      to the Licensor or its representatives, including but not limited to
      communication on electronic mailing lists, source code control systems,
      and issue tracking systems that are managed by, or on behalf of, the
      Licensor for the purpose of discussing and improving the Work, but
      excluding communication that is conspicuously marked or otherwise
      designated in writing by the copyright owner as "Not a Contribution."

      "Contributor" shall mean Licensor and any individual or Legal Entity
      on behalf of whom a Contribution has been received by Licensor and
      subsequently incorporated within the Work.

   2. Grant of Copyright License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      copyright license to reproduce, prepare Derivative Works of,
      publicly display, publicly perform, sublicense, and distribute the
      Work and such Derivative Works in Source or Object form.

   3. Grant of Patent License. Subject to the terms and conditions of
      this License, each Contributor hereby grants to You a perpetual,
      worldwide, non-exclusive, no-charge, royalty-free, irrevocable
      (except as stated in this section) patent license to make, have made,
      use, offer to sell, sell, import, and otherwise transfer the Work,
      where such license applies only to those patent claims licensable
      by such Contributor that are necessarily infringed by their
      Contribution(s) alone or by combination of their Contribution(s)
      with the Work to which such Contribution(s) was submitted. If You
      institute patent litigation against any entity (including a
      cross-claim or counterclaim in a lawsuit) alleging that the Work
      or a Contribution incorporated within the Work constitutes direct
      or contributory patent infringement, then any patent licenses
      granted to You under this License for that Work shall terminate
      as of the date such litigation is filed.

   4. Redistribution. You may reproduce and distribute copies of the
      Work or Derivative Works thereof in any medium, with or without
      modifications, and in Source or Object form, provided that You
      meet the following conditions:

      (a) You must give any other recipients of the Work or
          Derivative Works a copy of this License; and

      (b) You must cause any modified files to carry prominent notices
          stating that You changed the files; and

      (c) You must retain, in the Source form of any Derivative Works
          that You distribute, all copyright, patent, trademark, and
          attribution notices from the Source form of the Work,
          excluding those notices that do not pertain to any part of
          the Derivative Works; and

      (d) If the Work includes a "NOTICE" text file as part of its
          distribution, then any Derivative Works that You distribute must
          include a readable copy of the attribution notices contained
          within such NOTICE file, excluding those notices that do not
          pertain to any part of the Derivative Works, in at least one
          of the following places: within a NOTICE text file distributed
          as part of the Derivative Works; within the Source form or
          documentation, if provided along with the Derivative Works; or,
          within a display generated by the Derivative Works, if and
          wherever such third-party notices normally appear. The contents
          of the NOTICE file are for informational purposes only and
          do not modify the License. You may add Your own attribution
          notices within Derivative Works that You distribute, alongside
          or as an addendum to the NOTICE text from the Work, provided
          that such additional attribution notices cannot be construed
          as modifying the License.

      You may add Your own copyright statement to Your modifications and
      may provide additional or different license terms and conditions
      for use, reproduction, or distribution of Your modifications, or
      for any such Derivative Works as a whole, provided your use,
      reproduction, and distribution of the Work otherwise complies with
      the conditions stated in this License.

   5. Submission of Contributions. Unless You explicitly state otherwise,
      any Contribution intentionally submitted for inclusion in the Work
      by You to the Licensor shall be under the terms and conditions of
      this License, without any additional terms or conditions.
      Notwithstanding the above, nothing herein shall supersede or modify
      the terms of any separate license agreement you may have executed
      with Licensor regarding such Contributions.

   6. Trademarks. This License does not grant permission to use the trade
      names, trademarks, service marks, or product names of the Licensor,
      except as required for reasonable and customary use in describing the
      origin of the Work and reproducing the content of the NOTICE file.

   7. Disclaimer of Warranty. Unless required by applicable law or
      agreed to in writing, Licensor provides the Work (and each
      Contributor provides its Contributions) on an "AS IS" BASIS,
      WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
      implied, including, without limitation, any warranties or conditions
      of TITLE, NON-INFRINGEMENT, MERCHANTABILITY, or FITNESS FOR A
      PARTICULAR PURPOSE. You are solely responsible for determining the
      appropriateness of using or redistributing the Work and assume any
      risks associated with Your exercise of permissions under this License.

   8. Limitation of Liability. In no event and under no legal theory,
      whether in tort (including negligence), contract, or otherwise,
      unless required by applicable law (such as deliberate and grossly
      negligent acts) or agreed to in writing, shall any Contributor be
      liable to You for damages, including any direct, indirect, special,
      incidental, or consequential damages of any character arising as a
      result of this License or out of the use or inability to use the
      Work (including but not limited to damages for loss of goodwill,
      work stoppage, computer failure or malfunction, or any and all
      other commercial damages or losses), even if such Contributor
      has been advised of the possibility of such damages.

   9. Accepting Warranty or Additional Liability. While redistributing
      the Work or Derivative Works thereof, You may choose to offer,
      and charge a fee for, acceptance of support, warranty, indemnity,
      or other liability obligations and/or rights consistent with this
      License. However, in accepting such obligations, You may act only
      on Your own behalf and on Your sole responsibility, not on behalf
      of any other Contributor, and only if You agree to indemnify,
      defend, and hold each Contributor harmless for any liability
      incurred by, or claims asserted against, such Contributor by reason
      of your accepting any such warranty or additional liability.

   END OF TERMS AND CONDITIONS
