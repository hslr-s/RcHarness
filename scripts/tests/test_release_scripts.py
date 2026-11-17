"""Exercise architecture isolation with real Mach-O files and release metadata."""
import base64
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app_architecture import architectures, thin, verify
from validate_update_feed import read_dmg_info, validate


class ArchitectureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixtures = tempfile.TemporaryDirectory()
        cls.root = Path(cls.fixtures.name)
        source = cls.root / "main.c"
        source.write_text("int main(void) { return 0; }\n")
        for arch in ("arm64", "x86_64"):
            subprocess.run(["xcrun", "clang", "-arch", arch, "-mmacosx-version-min=14.0",
                            str(source), "-o", str(cls.root / arch)], check=True)
        subprocess.run(["xcrun", "lipo", "-create", str(cls.root / "arm64"),
                        str(cls.root / "x86_64"), "-output", str(cls.root / "universal")], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.fixtures.cleanup()

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.app = Path(self.scratch.name) / "RcHarness.app"

    def bundle(self, arch):
        main = self.app / "Contents/MacOS/RcHarness"
        driver = self.app / "Contents/PlugIns/RcHarnessMicrophone.driver/Contents/MacOS/RcHarnessMicrophone"
        for binary in (main, driver):
            binary.parent.mkdir(parents=True)
            shutil.copy2(self.root / arch, binary)
        self.info = self.app / "Contents/Info.plist"
        self.info.write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "14.0",
                                            "SUFeedURL": f"https://example.com/appcast-{arch}.xml"}))

    def test_both_single_architecture_bundles_pass(self):
        for arch in ("arm64", "x86_64"):
            with self.subTest(arch=arch):
                self.bundle(arch)
                verify(self.app, arch)
                shutil.rmtree(self.app)

    def test_universal_helper_is_rejected_then_thinned_without_breaking_symlink(self):
        self.bundle("arm64")
        framework = self.app / "Contents/Frameworks/Sparkle.framework"
        helper = framework / "Versions/B/Autoupdate"
        helper.parent.mkdir(parents=True)
        shutil.copy2(self.root / "universal", helper)
        link = framework / "Autoupdate"
        link.symlink_to("Versions/B/Autoupdate")
        with self.assertRaisesRegex(ValueError, "Only arm64"):
            verify(self.app, "arm64")
        thin(framework, "arm64")
        self.assertTrue(link.is_symlink())
        self.assertEqual(architectures(link), ["arm64"])
        verify(self.app, "arm64")

    def test_wrong_feed_and_missing_driver_are_rejected(self):
        self.bundle("x86_64")
        with self.assertRaisesRegex(ValueError, "update feed"):
            verify(self.app, "arm64")
        shutil.rmtree(self.app / "Contents/PlugIns")
        with self.assertRaisesRegex(ValueError, "Missing application or HAL"):
            verify(self.app, "x86_64")

    def test_thinning_never_substitutes_a_missing_slice(self):
        self.bundle("arm64")
        with self.assertRaisesRegex(ValueError, "Missing x86_64 slice"):
            thin(self.app, "x86_64")


class DMGPackagingTests(unittest.TestCase):
    def test_release_signs_dmg_before_notarization_and_supplies_assessment_context(self):
        workflow = (Path(__file__).resolve().parents[2] / ".github/workflows/release.yml").read_text()
        step = workflow.split("      - name: Notarize and staple distribution DMG\n", 1)[1]
        commands = textwrap.dedent(step.split("        run: |\n", 1)[1].split("\n      - name:", 1)[0])
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            binaries = root / "bin"
            binaries.mkdir()
            # Exercise the actual workflow shell without Apple credentials or
            # changes to the host's Gatekeeper policy. Model the two DMG gates:
            # a signed image before submission, and context for open assessment.
            tool = binaries / "release-tool"
            tool.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
                import json, os, sys
                from pathlib import Path
                name, args = Path(sys.argv[0]).name, sys.argv[1:]
                root = Path(os.environ["RUNNER_TEMP"])
                signed = root / "dmg-signed"
                if name == "codesign":
                    if "--sign" in args:
                        assert args[args.index("--sign") + 1] == os.environ["RC_HARNESS_SIGNING_IDENTITY"]
                        assert "--timestamp" in args
                        signed.touch()
                    else:
                        assert "--verify" in args and signed.exists()
                elif name == "xcrun":
                    assert signed.exists(), "DMG must be signed before notarization"
                    if args[:2] == ["notarytool", "submit"]:
                        print(json.dumps({"status": "Accepted"}))
                    else:
                        assert args[:2] in (["stapler", "staple"], ["stapler", "validate"])
                elif name == "jq":
                    print(json.load(open(args[-1]))["status"])
                elif name == "spctl":
                    if "--context" not in args or args[args.index("--context") + 1] != "context:primary-signature":
                        sys.exit("source=Insufficient Context")
                    assert signed.exists()
                    (root / "dmg-assessed").touch()
                else:
                    assert name == "hdiutil" and args[0] == "verify"
                '''))
            tool.chmod(0o755)
            for name in ("codesign", "xcrun", "jq", "spctl", "hdiutil"):
                (binaries / name).symlink_to(tool.name)
            for extension in ("dmg", "zip"):
                (root / f"RcHarness-v1.2.3-macos-arm64.{extension}").write_bytes(b"release fixture")
            result = subprocess.run(["/bin/bash", "-e", "-o", "pipefail", "-c", commands],
                env={**os.environ, "PATH": str(binaries) + os.pathsep + os.defpath,
                     "RUNNER_TEMP": str(root), "DIST_DIR": str(root), "RELEASE_TAG": "v1.2.3",
                     "RC_HARNESS_ARCH": "arm64", "KEYCHAIN_PATH": str(root / "release.keychain-db"),
                     "RC_HARNESS_SIGNING_IDENTITY": "test-distribution-identity"},
                capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue((root / "dmg-assessed").exists())
            self.assertTrue((root / "SHA256SUMS-arm64").exists())

    def test_package_script_keeps_application_bundle(self):
        with tempfile.TemporaryDirectory() as scratch:
            root = Path(scratch)
            app = root / "RcHarness.app"
            info = app / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(plistlib.dumps({
                "CFBundleIdentifier": "vip.tokenzz.rcharness",
                "CFBundleShortVersionString": "1.2.3",
            }))
            dmg = root / "RcHarness.dmg"
            subprocess.run([
                str(Path(__file__).resolve().parents[1] / "package_dmg.sh"),
                str(app), str(dmg), "RcHarness Test",
            ], check=True)
            self.assertEqual(read_dmg_info(dmg)["CFBundleIdentifier"], "vip.tokenzz.rcharness")


class UpdateFeedTests(unittest.TestCase):
    def fixture(self, root, arch, bundled_arch=None):
        repository, tag = "tokenzz-vip/RcHarness", "v1.2.3"
        archive = root / f"RcHarness-{tag}-macos-{arch}.dmg"
        feed = root / f"appcast-{arch}.xml"
        info = {"CFBundleVersion": "123", "CFBundleShortVersionString": "1.2.3",
                "LSMinimumSystemVersion": "14.0",
                "SUFeedURL": f"https://github.com/{repository}/releases/latest/download/appcast-{bundled_arch or arch}.xml"}
        stage = root / f"stage-{arch}"
        app_info = stage / "RcHarness.app/Contents/Info.plist"
        app_info.parent.mkdir(parents=True)
        app_info.write_bytes(plistlib.dumps(info))
        subprocess.run(["hdiutil", "create", "-quiet", "-srcfolder", str(stage),
                        "-format", "UDZO", "-ov", str(archive)], check=True)
        ns = "http://www.andymatuschak.org/xml-namespaces/sparkle"
        rss = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
        for key, value in (("version", "123"), ("shortVersionString", "1.2.3"), ("minimumSystemVersion", "14.0")):
            ET.SubElement(item, f"{{{ns}}}{key}").text = value
        ET.SubElement(item, "enclosure", {"url": f"https://github.com/{repository}/releases/download/{tag}/{archive.name}",
                                         "length": str(archive.stat().st_size),
                                         f"{{{ns}}}edSignature": base64.b64encode(bytes(64)).decode()})
        ET.ElementTree(rss).write(feed)
        return feed, archive, tag, repository, arch

    def test_each_architecture_has_matching_release_metadata(self):
        with tempfile.TemporaryDirectory() as scratch:
            for arch in ("arm64", "x86_64"):
                with self.subTest(arch=arch):
                    validate(*self.fixture(Path(scratch), arch))

    def test_swapped_architecture_feed_inside_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            args = self.fixture(Path(scratch), "x86_64", bundled_arch="arm64")
            with self.assertRaisesRegex(ValueError, "Application update feed"):
                validate(*args)

    def test_mislabeled_release_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as scratch:
            args = self.fixture(Path(scratch), "arm64")
            with self.assertRaisesRegex(ValueError, "Archive name"):
                validate(*args[:-1], "x86_64")


if __name__ == "__main__":
    unittest.main()
