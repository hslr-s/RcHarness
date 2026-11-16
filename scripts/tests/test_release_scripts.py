"""Exercise architecture isolation with real Mach-O files and release metadata."""
import base64
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from app_architecture import architectures, thin, verify
from validate_update_feed import validate


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


class UpdateFeedTests(unittest.TestCase):
    def fixture(self, root, arch, bundled_arch=None):
        repository, tag = "tokenzz-vip/RcHarness", "v1.2.3"
        archive = root / f"RcHarness-{tag}-macos-{arch}.zip"
        feed = root / f"appcast-{arch}.xml"
        info = {"CFBundleVersion": "123", "CFBundleShortVersionString": "1.2.3",
                "LSMinimumSystemVersion": "14.0",
                "SUFeedURL": f"https://github.com/{repository}/releases/latest/download/appcast-{bundled_arch or arch}.xml"}
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("RcHarness.app/Contents/Info.plist", plistlib.dumps(info))
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
