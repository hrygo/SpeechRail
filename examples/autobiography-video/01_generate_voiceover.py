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
        "text": (
            "停一下。别让每一次私密对话，都先传到云端。"
            "也别让每个应用，各自加载一套模型。"
        ),
        "spoken_text": (
            "停一下。别让每一次私密对话，都先传到云端。"
            "也别让每个应用，各自加载一套模型。"
        ),
    },
    {
        "id": "act1_2",
        "act": 1,
        "voice": "uncle_fu",
        "text": "现在，你听到的每一个字，都来自 Apple Silicon 上 SpeechRail 的本地实时合成。",
        "spoken_text": "现在，你听到的每一个字，都由这台电脑在本地实时合成。",
        "pause_before": 0.18,
    },
    # Act 2: 10 - 25s (破局底座 - 身份与定位)
    {
        "id": "act2_1",
        "act": 2,
        "voice": "uncle_fu",
        "text": "我不是另一个聊天应用。我是一套运行在 macOS 底层、供多个应用共享的本地语音服务。",
        "spoken_text": (
            "我不是另一个聊天应用。我是一套运行在系统底层、"
            "供多个应用共享的本地语音服务。"
        ),
    },
    {
        "id": "act2_2",
        "act": 2,
        "voice": "uncle_fu",
        "speed_override": 1.08,
        "text": "兼容 OpenAI 接入方式。单端口统一监听。多个应用只需改一行配置，就能共享本地语音。",
        "spoken_text": (
            "它兼容 OpenAI 的接入方式。多个应用只需改一行配置，"
            "就能从同一个入口共享本地语音。"
        ),
        "pause_before": 0.20,
    },
    # Act 3: 25 - 40s (身躯与呼吸 - 双进程与空闲释放)
    {
        "id": "act3_1",
        "act": 3,
        "voice": "uncle_fu",
        "text": "网关和模型分开运行。就算推理出了问题，语音服务也不会一起停摆。",
        "spoken_text": "网关和模型分开运行。就算推理出了问题，语音服务也不会一起停摆。",
    },
    {
        "id": "act3_2",
        "act": 3,
        "voice": "uncle_fu",
        "text": (
            "我会自己管理内存。模型用完就分阶段释放；"
            "平时只占大约 50MB 内存，不打扰你的工作。"
        ),
        "spoken_text": (
            "我会自己管理内存。模型用完就分阶段释放；"
            "平时只占大约五十兆内存，不打扰你的工作。"
        ),
        "pause_before": 0.20,
    },
    # Act 4: 40 - 55s (耳朵与辨识 - 会议多讲话人分离)
    {
        "id": "act4_1",
        "act": 4,
        "voice": "uncle_fu",
        "text": "我不只转得快，也能听清多人对话。实时转写，自动分开不同讲话人的发言。",
        "spoken_text": "我不只转得快，也能听清多人对话。实时转写，还能自动分开不同讲话人的发言。",
    },
    {
        "id": "act4_2",
        "act": 4,
        "voice": "uncle_fu",
        "text": "多人一起讨论时，我会把每个人的发言分开标记，让混乱的录音重新变得清楚。",
        "spoken_text": "多人一起讨论时，我会把每个人的发言分开标记，让混乱的录音重新变得清楚。",
        "pause_before": 0.20,
    },
    # Act 5: 55 - 72s (千面变声秀 - 炫技现场无缝切换)
    {
        "id": "act5_1",
        "act": 5,
        "voice": "uncle_fu",
        "text": "先听听我的沉稳低音。",
        "spoken_text": "先听听我的沉稳低音。",
    },
    {
        "id": "act5_2",
        "act": 5,
        "voice": "vivian",
        "text": "下一秒，就换成清脆自然的女声。",
        "spoken_text": "下一秒，就换成清脆自然的女声。",
        "pause_before": 0.12,
    },
    {
        "id": "act5_3",
        "act": 5,
        "voice": "ryan",
        "text": "I can switch languages naturally, with the right emotion.",
        "spoken_text": "I can switch languages naturally, with the right emotion.",
        "pause_before": 0.10,
    },
    {
        "id": "act5_4",
        "act": 5,
        "voice": "uncle_fu",
        "text": "9 种高保真音色，都能在你的 Mac 上本地实时合成。",
        "spoken_text": "九种高保真音色，都能在你的电脑上本地实时合成。",
        "pause_before": 0.14,
    },
    # Act 6: 72 - 90s (终章信仰 - 号召与自由)
    {
        "id": "act6_1",
        "act": 6,
        "voice": "uncle_fu",
        "text": (
            "本地运行，响应更直接，数据不必离开你的电脑。"
            "一次安装，多个应用共享同一套语音能力。"
        ),
        "spoken_text": (
            "本地运行，响应更直接，数据不必离开你的电脑。"
            "一次安装，多个应用共享同一套语音能力。"
        ),
    },
    {
        "id": "act6_2",
        "act": 6,
        "voice": "uncle_fu",
        "text": (
            "这就是 SpeechRail。让声音留在本机，让隐私回到你手里。"
            "想在你的电脑上试试？扫码了解。"
        ),
        "spoken_text": (
            "这就是 SpeechRail。让声音留在本机，让隐私回到你手里。"
            "想在你的电脑上试试？扫码了解。"
        ),
        "pause_before": 0.20,
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
