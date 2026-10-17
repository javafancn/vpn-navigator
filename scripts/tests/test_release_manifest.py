import importlib.util
import pathlib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("manifest", pathlib.Path(__file__).parents[1] / "release-manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)

class DeploymentMetadataTests(unittest.TestCase):
    def parse(self, value):
        with patch.object(manifest.subprocess, "check_output", return_value=value):
            return manifest.minimum_versions(pathlib.Path("fixture"))

    def test_build_version_ignores_linker_tool_version(self):
        self.assertEqual(self.parse("""Load command 10
      cmd LC_BUILD_VERSION
  cmdsize 32
 platform 1
    minos 13.0
      sdk 15.5
   ntools 1
     tool LD
  version 1167.5
Load command 11
      cmd LC_SOURCE_VERSION
  version 99.0
"""), ["13.0"])

    def test_legacy_and_multiple_slices(self):
        self.assertEqual(self.parse("""cmd LC_VERSION_MIN_MACOSX
version 13.0
sdk 15.0
cmd LC_UUID
cmd LC_BUILD_VERSION
minos 13.1
sdk 15.0
tool LD
version 1167.5
"""), ["13.0", "13.1"])

    def test_missing_metadata_is_rejected(self):
        with self.assertRaises(RuntimeError):
            self.parse("cmd LC_SOURCE_VERSION\nversion 1.0\n")

if __name__ == "__main__":
    unittest.main()
