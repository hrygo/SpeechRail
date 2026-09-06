#!/usr/bin/env python3
"""
SpeechRail Autobiography Video - Voiceover Generator (V2: High-Hook Script)
Synthesizes speech using the local SpeechRail instance (127.0.0.1:8201).
"""

import hashlib
import json
import os
import subprocess
import urllib.request
from pathlib import Path

BUILD_DIR = Path(__file__).parent / "build"
BUILD_DIR.mkdir(parents=True, exist_ok=True)
AUDIO_DIR = BUILD_DIR / "audio_segments_v2"
AUDIO_DIR.mkdir(parents=True, exist_ok=True)
SHOWCASE_AUDIO_DIR = BUILD_DIR / "audio_showcase_v1"
SHOWCASE_AUDIO_DIR.mkdir(parents=True, exist_ok=True)

SPEECHRAIL_URL = "http://127.0.0.1:8201/v1/audio/speech"
api_key = os.environ.get("SPEECHRAIL_API_KEY", "")

HEADERS = {"Content-Type": "application/json"}
if api_key:
    HEADERS["Authorization"] = f"Bearer {api_key}"

# The revised high-hook script
SCRIPT_SEGMENTS = [
    # Act 1: 0 - 10s (🔥 黄金 Hook - 直击灵魂 - 反常识 - 亮出本色)
    {
        "id": "act1_1",
        "act": 1,
        "voice": "uncle_fu",
        "text": "停下！别再把你每一次私密对话上传云端，也别再让笨重的模型拖垮你 Mac 的内存了。",
    },
    {
        "id": "act1_2",
        "act": 1,
        "voice": "uncle_fu",
        "text": "".join(
            (
                "我是 SpeechRail——此刻你听到的每一个字，都来自我在 Apple Silicon ",
                "上的本地实时发声。",
            )
        ),
    },
    # Act 2: 10 - 25s (破局底座 - 身份与定位)
    {
        "id": "act2_1",
        "act": 2,
        "voice": "uncle_fu",
        "text": "我不是又一个封闭的客户端，而是默默常驻在 macOS 底层的独立语音基座。",
    },
    {
        "id": "act2_2",
        "act": 2,
        "voice": "uncle_fu",
        "speed_override": 1.08,
        # Keep product notation in the subtitle, but spell symbols out for
        # the Chinese TTS voice so "1:1" is not read as "One D One".
        "text": (
            "1:1 兼容 OpenAI 协议，单端口监听。全机所有的 Agent 和应用，改一行代码，即插即用。"
        ),
        "spoken_text": (
            "接口与 OpenAI 协议一比一兼容，单端口监听。全机所有的智能体和应用，"
            "改一行代码，即插即用。"
        ),
    },
    # Act 3: 25 - 40s (身躯与呼吸 - 双进程与空闲释放)
    {
        "id": "act3_1",
        "act": 3,
        "voice": "uncle_fu",
        "text": "双物理进程隔离，重型推理即使异常崩溃，网关也绝不宕机。",
    },
    {
        "id": "act3_2",
        "act": 3,
        "voice": "uncle_fu",
        "text": "".join(
            (
                "更体贴的是我的呼吸——两阶段空闲卸载，推理完毕自动释放显存，平时常驻仅需 50 兆，",
                "绝不打扰你的日常工作。",
            )
        ),
    },
    # Act 4: 40 - 55s (耳朵与辨识 - 会议多讲话人分离)
    {
        "id": "act4_1",
        "act": 4,
        "voice": "uncle_fu",
        "text": "我不但听得快，更能听得清。毫秒级实时流式转录，原生集成 Sortformer 讲话人分离。",
    },
    {
        "id": "act4_2",
        "act": 4,
        "voice": "uncle_fu",
        "text": "多人激烈讨论中，我能分秒不差指出谁说了什么，让混乱的会议录音瞬间井井有条。",
    },
    # Act 5: 55 - 72s (千面变声秀 - 炫技现场无缝切换)
    {
        "id": "act5_1",
        "act": 5,
        "voice": "uncle_fu",
        "text": "你能听到我沉稳低沉的思考，",
    },
    {
        "id": "act5_2",
        "act": 5,
        "voice": "vivian",
        "text": "也能下一秒变成清脆自然的表达，",
    },
    {
        "id": "act5_3",
        "act": 5,
        "voice": "ryan",
        "text": "And seamless multilingual speech with native emotions.",
    },
    {
        "id": "act5_4",
        "act": 5,
        "voice": "uncle_fu",
        "text": "9 款高保真跨语言音色，全部由你的 Mac 本地现场渲染。",
    },
    # Act 6: 72 - 90s (终章信仰 - 号召与自由)
    {
        "id": "act6_1",
        "act": 6,
        "voice": "uncle_fu",
        "text": "纯离线零延迟，数据永不离机。一次安装，全机无限量免费调用。",
    },
    {
        "id": "act6_2",
        "act": 6,
        "voice": "uncle_fu",
        "text": "这就是 SpeechRail——把声音还给本地，把隐私还给你自己。现在，你的 Mac 准备好了吗？",
    },
]

# Six voices that are listed in Act 5 but do not speak in the formal
# narration. They become a short, multilingual postscript on the QR page.
VOICE_SHOWCASE_SEGMENTS = [
    {
        "id": "showcase_serena",
        "voice": "serena",
        "text": "SpeechRail。",
        "description": "温柔中文女声",
    },
    {
        "id": "showcase_dylan",
        "voice": "dylan",
        "text": "留在本地。",
        "description": "北京青年男声",
    },
    {
        "id": "showcase_eric",
        "voice": "eric",
        "text": "本地运行。",
        "description": "成都活力男声",
    },
    {
        "id": "showcase_aiden",
        "voice": "aiden",
        "text": "Stay local.",
        "description": "阳光美式男声",
    },
    {
        "id": "showcase_ono_anna",
        "voice": "ono_anna",
        "text": "ローカル。",
        "description": "轻快日语女声",
    },
    {
        "id": "showcase_sohee",
        "voice": "sohee",
        "text": "로컬.",
        "caption": "LOCAL VOICE.",
        "description": "温暖韩语女声",
    },
]


def synthesize_audio(text: str, voice: str, out_path: Path):
    cache_path = out_path.with_suffix(out_path.suffix + ".sha256")
    cache_key = hashlib.sha256(f"{voice}\0{text}".encode()).hexdigest()
    if (
        out_path.exists()
        and out_path.stat().st_size > 1000
        and cache_path.exists()
        and cache_path.read_text(encoding="utf-8").strip() == cache_key
    ):
        print(f"File {out_path.name} exists, skipping.")
        return

    payload = json.dumps(
        {"model": "tts-1", "input": text, "voice": voice, "response_format": "wav"}
    ).encode("utf-8")

    req = urllib.request.Request(SPEECHRAIL_URL, data=payload, headers=HEADERS)
    print(f"Synthesizing [{voice}]: '{text[:22]}' -> {out_path.name}")
    with urllib.request.urlopen(req) as resp:
        content = resp.read()
        with out_path.open("wb") as f:
            f.write(content)
    cache_path.write_text(cache_key + "\n", encoding="utf-8")


def get_audio_duration(file_path: Path) -> float:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(file_path),
    ]
    res = subprocess.check_output(cmd).decode().strip()
    return float(res)


def main():
    print("--- Step 1: Synthesizing V2 Hook voiceover segments via SpeechRail ---")
    results = []
    for item in SCRIPT_SEGMENTS:
        out_file = AUDIO_DIR / f"{item['id']}_{item['voice']}.wav"
        spoken_text = item.get("spoken_text", item["text"])
        synthesize_audio(spoken_text, item["voice"], out_file)
        dur = get_audio_duration(out_file)
        print(f" -> Segment {item['id']} duration: {dur:.2f}s")
        results.append({**item, "path": str(out_file), "duration": dur})

    with (BUILD_DIR / "segments_meta_v2.json").open("w", encoding="utf-8") as f:
        json.dump(results, f, ensure_ascii=False, indent=2)
    print("All V2 segments synthesized successfully!")

    showcase_results = []
    print("--- Voice showcase: synthesizing six voices not used in the narration ---")
    for item in VOICE_SHOWCASE_SEGMENTS:
        out_file = SHOWCASE_AUDIO_DIR / f"{item['id']}_{item['voice']}.wav"
        spoken_text = item.get("spoken_text", item["text"])
        synthesize_audio(spoken_text, item["voice"], out_file)
        dur = get_audio_duration(out_file)
        print(f" -> Showcase {item['voice']} duration: {dur:.2f}s")
        showcase_results.append({**item, "path": str(out_file), "duration": dur})

    with (BUILD_DIR / "voice_showcase_meta_v1.json").open("w", encoding="utf-8") as f:
        json.dump(showcase_results, f, ensure_ascii=False, indent=2)
    print("Six-voice showcase synthesized successfully!")


if __name__ == "__main__":
    main()
