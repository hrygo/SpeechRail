.PHONY: all voiceover bgm mix spectrum video clean

all: voiceover bgm mix spectrum video

mix: voiceover bgm
spectrum: mix
video: mix spectrum

voiceover:
	uv run --with pillow --with numpy python 01_generate_voiceover.py

bgm:
	uv run --with numpy python 02_generate_bgm.py

mix:
	python3 03_process_audio_and_mix.py

spectrum:
	uv run --with numpy python 04_analyze_waveform.py

video:
	uv run --with pillow --with numpy --with qrcode python 05_render_video.py

clean:
	rm -rf build/
