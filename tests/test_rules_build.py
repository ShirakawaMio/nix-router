import importlib.util
import os
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


SCRIPT = Path(
    os.environ.get(
        "MY_ROUTER_RULES_SCRIPT",
        Path(__file__).parents[1] / "scripts" / "my-router-rules-build.py",
    )
)
SPEC = importlib.util.spec_from_file_location("rules_build", SCRIPT)
rules_build = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(rules_build)


class RulesBuildTests(unittest.TestCase):
    def test_prebuilt_url_and_source_urls_are_mutually_exclusive(self):
        config = {
            "ads": {
                "prebuilt_base_url": "https://example.test/providers",
                "urls": ["https://example.test/source.txt"],
            }
        }

        with self.assertRaises(SystemExit):
            rules_build.validate_config(config)

    def test_prebuilt_ads_are_copied_and_local_rules_are_appended(self):
        responses = {
            "https://example.test/providers/ads.yaml": 'payload:\n  - "+.remote.example"\n',
            "https://example.test/providers/ads-shadowrocket.list": (
                "DOMAIN-SUFFIX,remote.example\n"
            ),
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            providers = Path(temp_dir)
            with mock.patch.object(rules_build, "fetch_text", side_effect=responses.__getitem__):
                rules_build.write_prebuilt_ads(
                    providers,
                    "https://example.test/providers",
                    ["+.local.example"],
                )

            self.assertEqual(
                (providers / "ads.yaml").read_text(),
                'payload:\n  - "+.remote.example"\n  - "+.local.example"\n',
            )
            self.assertEqual(
                (providers / "ads-shadowrocket.list").read_text(),
                "DOMAIN-SUFFIX,remote.example\nDOMAIN-SUFFIX,local.example\n",
            )

    def test_failed_download_keeps_existing_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            providers = Path(temp_dir)
            (providers / "ads.yaml").write_text("old-mihomo\n")
            (providers / "ads-shadowrocket.list").write_text("old-shadowrocket\n")

            with mock.patch.object(
                rules_build,
                "fetch_text",
                side_effect=["payload:\n", urllib.error.URLError("offline")],
            ):
                with self.assertRaises(urllib.error.URLError):
                    rules_build.write_prebuilt_ads(
                        providers,
                        "https://example.test/providers",
                        [],
                    )

            self.assertEqual((providers / "ads.yaml").read_text(), "old-mihomo\n")
            self.assertEqual(
                (providers / "ads-shadowrocket.list").read_text(),
                "old-shadowrocket\n",
            )


if __name__ == "__main__":
    unittest.main()
