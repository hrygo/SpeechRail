from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parents[1]
SCRIPT = SKILL_DIR / "scripts" / "inspect_media.py"


class InspectMediaCliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if shutil.which("ffmpeg") is None or shutil.which("ffprobe") is None:
            raise unittest.SkipTest("ffmpeg and ffprobe are required")

        cls.temp_dir = tempfile.TemporaryDirectory(prefix="video-podcast-inspect-")
        cls.media_path = Path(cls.temp_dir.name) / "fixture.mp4"
        cls.silent_media_path = Path(cls.temp_dir.name) / "silent-fixture.mp4"
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=320x180:r=25:d=1.2",
                "-f",
                "lavfi",
                "-i",
                "sine=frequency=440:sample_rate=44100:duration=1.2",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-t",
                "1.2",
                str(cls.media_path),
            ],
            check=True,
        )
        subprocess.run(
            [
                "ffmpeg",
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=320x180:r=25:d=1.2",
                "-f",
                "lavfi",
                "-i",
                "anullsrc=channel_layout=stereo:sample_rate=44100",
                "-c:v",
                "libx264",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-t",
                "1.2",
                str(cls.silent_media_path),
            ],
            check=True,
        )

    @classmethod
    def tearDownClass(cls):
        cls.temp_dir.cleanup()

    def run_inspector(self, *args: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), *map(str, args)],
            capture_output=True,
            text=True,
            check=False,
        )

    def parse_output(self, result: subprocess.CompletedProcess[str]) -> dict:
        self.assertTrue(result.stdout, result.stderr)
        return json.loads(result.stdout)

    def test_valid_media_reports_streams_and_loudness(self):
        result = self.run_inspector(self.media_path, "--loudness")

        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        report = self.parse_output(result)
        self.assertEqual(report["status"], "pass")
        self.assertTrue(report["human_review_required"])
        self.assertEqual(report["media"]["video"]["codec_type"], "video")
        self.assertEqual(report["media"]["audio"]["codec_type"], "audio")
        self.assertEqual(report["checks"]["audio_video_duration"]["status"], "pass")
        self.assertEqual(report["checks"]["loudness"]["status"], "pass")
        self.assertIsNotNone(report["checks"]["loudness"]["measured"]["integrated_lufs"])

    def test_expected_duration_mismatch_returns_technical_failure(self):
        result = self.run_inspector(
            self.media_path,
            "--expected-duration",
            "9",
            "--duration-tolerance",
            "0.1",
        )

        self.assertEqual(result.returncode, 1, result.stderr or result.stdout)
        report = self.parse_output(result)
        self.assertEqual(report["status"], "fail")
        self.assertEqual(report["checks"]["expected_duration"]["status"], "fail")

    def test_missing_media_returns_data_error(self):
        result = self.run_inspector(self.media_path.parent / "missing.mp4")

        self.assertEqual(result.returncode, 2)
        report = self.parse_output(result)
        self.assertEqual(report["status"], "error")
        self.assertEqual(report["error"]["kind"], "input")

    def test_unmeasurable_loudness_is_unknown(self):
        result = self.run_inspector(self.silent_media_path, "--loudness")

        self.assertEqual(result.returncode, 2, result.stderr or result.stdout)
        report = self.parse_output(result)
        self.assertEqual(report["status"], "unknown")
        self.assertEqual(report["checks"]["loudness"]["status"], "unknown")

    def test_metadata_only_does_not_claim_loudness_or_modify_media(self):
        before = hashlib.sha256(self.media_path.read_bytes()).hexdigest()
        result = self.run_inspector(self.media_path)
        report = self.parse_output(result)
        self.assertEqual(result.returncode, 0, report)
        self.assertEqual(report["checks"]["loudness"]["status"], "not_requested")
        self.assertEqual(report["sha256"], before)
        self.assertEqual(hashlib.sha256(self.media_path.read_bytes()).hexdigest(), before)

    def test_threshold_implicitly_measures_and_can_fail(self):
        result = self.run_inspector(self.media_path, "--max-true-peak", "-60")
        report = self.parse_output(result)
        self.assertEqual(result.returncode, 1, report)
        self.assertEqual(report["checks"]["true_peak"]["status"], "fail")

    def test_wrong_stream_type_is_input_error(self):
        result = self.run_inspector(self.media_path, "--audio-index", "0")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.parse_output(result)["error"]["kind"], "input")

    def test_nonfinite_and_negative_options_are_json_errors(self):
        for option, value in [
            ("--target-lufs", "nan"),
            ("--timeout", "0"),
            ("--av-tolerance", "-1"),
            ("--audio-index", "-1"),
        ]:
            with self.subTest(option=option):
                result = self.run_inspector(self.media_path, option, value)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.parse_output(result)["error"]["kind"], "input")

    def test_selected_audio_is_measured_instead_of_first_track(self):
        multi = self.media_path.parent / "multi.mp4"
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-i",
                str(self.media_path),
                "-i",
                str(self.silent_media_path),
                "-map",
                "0:v:0",
                "-map",
                "0:a:0",
                "-map",
                "1:a:0",
                "-c",
                "copy",
                str(multi),
            ],
            check=True,
        )
        result = self.run_inspector(multi, "--audio-index", "2", "--loudness")
        report = self.parse_output(result)
        self.assertEqual(result.returncode, 2, report)
        self.assertEqual(report["media"]["audio"]["index"], 2)
        self.assertEqual(report["checks"]["loudness"]["status"], "unknown")

    def test_container_duration_does_not_fill_unknown_stream_duration(self):
        media = self.media_path.parent / "unknown-duration.mkv"
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-i",
                str(self.media_path),
                "-c",
                "copy",
                str(media),
            ],
            check=True,
        )
        result = self.run_inspector(media)
        report = self.parse_output(result)
        self.assertEqual(result.returncode, 2, report)
        self.assertEqual(report["checks"]["audio_video_duration"]["status"], "unknown")

    def test_equal_durations_with_offset_are_not_synchronized(self):
        media = self.media_path.parent / "offset.mp4"
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-i",
                str(self.media_path),
                "-itsoffset",
                "0.4",
                "-i",
                str(self.media_path),
                "-map",
                "0:v:0",
                "-map",
                "1:a:0",
                "-c",
                "copy",
                str(media),
            ],
            check=True,
        )
        result = self.run_inspector(media, "--av-tolerance", "0.1")
        report = self.parse_output(result)
        self.assertEqual(result.returncode, 1, report)
        self.assertEqual(report["checks"]["audio_video_start"]["status"], "fail")


if __name__ == "__main__":
    unittest.main()
