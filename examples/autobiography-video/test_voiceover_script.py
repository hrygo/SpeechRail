import runpy
import unittest
from pathlib import Path

SCRIPT_PATH = Path(__file__).with_name("01_generate_voiceover.py")


def load_segments() -> list[dict[str, object]]:
    namespace = runpy.run_path(str(SCRIPT_PATH))
    return namespace["SCRIPT_SEGMENTS"]


class VoiceoverScriptTests(unittest.TestCase):
    def test_spoken_text_uses_pronunciation_safe_terms(self) -> None:
        segments = {item["id"]: item for item in load_segments()}
        expected_fragments = {
            "act1_1": "别让每一次私密对话",
            "act1_2": "本地实时合成",
            "act2_1": "聊天应用",
            "act2_2": "接入方式",
            "act3_1": "网关和模型分开运行",
            "act3_2": "自己管理内存",
            "act4_1": "听清多人对话",
            "act4_2": "每个人的发言分开标记",
            "act5_1": "沉稳低音",
            "act5_2": "清脆自然的女声",
            "act5_3": "I can switch languages naturally",
            "act5_4": "九种高保真音色",
            "act6_1": "本地运行，响应更直接",
            "act6_2": "扫码了解",
        }

        for segment_id, fragment in expected_fragments.items():
            spoken_text = segments[segment_id].get("spoken_text", segments[segment_id]["text"])
            self.assertIn(fragment, spoken_text, segment_id)

        for item in segments.values():
            spoken_text = item.get("spoken_text", item["text"])
            self.assertNotIn("——", spoken_text, item["id"])
            self.assertNotIn("单端口监听", spoken_text, item["id"])
            self.assertNotIn("终身", spoken_text, item["id"])
            self.assertNotIn("无限量", spoken_text, item["id"])
            self.assertNotIn("永不", spoken_text, item["id"])
            self.assertNotIn("绝不", spoken_text, item["id"])
            self.assertNotIn("分秒不差", spoken_text, item["id"])
            self.assertNotIn("两阶段空闲卸载", spoken_text, item["id"])
        self.assertNotIn("50", segments["act3_2"]["spoken_text"])
        self.assertNotIn("9", segments["act5_4"]["spoken_text"])

    def test_display_copy_keeps_technical_terms_where_they_help(self) -> None:
        segments = {item["id"]: item for item in load_segments()}
        expected_display_fragments = {
            "act1_2": "Apple Silicon",
            "act2_1": "macOS",
            "act2_2": "OpenAI 接入方式",
            "act3_2": "50MB",
            "act5_4": "9 种",
            "act6_2": "扫码了解",
        }
        for segment_id, fragment in expected_display_fragments.items():
            self.assertIn(fragment, segments[segment_id]["text"], segment_id)

    def test_segment_pauses_are_explicit_and_contextual(self) -> None:
        segments = {item["id"]: item for item in load_segments()}
        expected_pauses = {
            "act1_2": 0.18,
            "act2_2": 0.20,
            "act3_2": 0.20,
            "act4_2": 0.20,
            "act5_2": 0.12,
            "act5_3": 0.10,
            "act5_4": 0.14,
            "act6_2": 0.20,
        }

        for segment_id, expected in expected_pauses.items():
            self.assertAlmostEqual(segments[segment_id]["pause_before"], expected)


if __name__ == "__main__":
    unittest.main()
