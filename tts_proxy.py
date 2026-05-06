#!/usr/bin/env python3
"""Edge TTS HTTP 代理服务器.
ArkTS 端通过 HTTP POST 请求此代理，代理使用 Python edge-tts 库连接 Edge TTS 并返回音频。
"""
import asyncio
import io
import json
import os
import sys

import edge_tts
from aiohttp import web


async def handle_tts(request):
    """接收 TTS 请求，返回 MP3 音频数据."""
    try:
        body = await request.json()
    except Exception as e:
        return web.json_response({"error": f"JSON 解析失败: {e}"}, status=400)

    text = body.get("text", "")
    voice = body.get("voice", "zh-CN-XiaoxiaoNeural")
    rate = body.get("rate", "+0%")
    volume = body.get("volume", "+0%")

    if not text:
        return web.json_response({"error": "text 不能为空"}, status=400)

    print(f"[TTS] voice={voice}, text={text[:50]}...")

    try:
        communicate = edge_tts.Communicate(text, voice, rate=rate, volume=volume)
        audio_data = io.BytesIO()
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                audio_data.write(chunk["data"])

        mp3_bytes = audio_data.getvalue()
        if not mp3_bytes:
            return web.json_response({"error": "未收到音频数据"}, status=500)

        print(f"[TTS] ✓ 合成成功, {len(mp3_bytes)} bytes")
        return web.Response(
            body=mp3_bytes,
            content_type="audio/mpeg",
            headers={
                "X-Audio-Length": str(len(mp3_bytes)),
                "Access-Control-Allow-Origin": "*",
            },
        )
    except edge_tts.exceptions.WebSocketError as e:
        print(f"[TTS] WebSocketError: {e}")
        return web.json_response({"error": f"WebSocket 连接失败: {e}"}, status=502)
    except Exception as e:
        print(f"[TTS] 错误: {e}")
        return web.json_response({"error": str(e)}, status=500)


async def handle_list_voices(request):
    """返回可用语音列表."""
    try:
        voices = await edge_tts.list_voices()
        # 只取中文和英文语音
        filtered = [
            {
                "name": v["ShortName"],
                "locale": v["Locale"],
                "gender": v["Gender"],
                "description": v.get("LocalName", v["ShortName"]),
            }
            for v in voices
            if v["Locale"].startswith("zh-") or v["Locale"].startswith("en-")
        ]
        return web.json_response(filtered)
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


async def handle_health(request):
    return web.json_response({"status": "ok"})


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 9191
    app = web.Application()
    app.router.add_post("/tts", handle_tts)
    app.router.add_get("/voices", handle_list_voices)
    app.router.add_get("/health", handle_health)

    print(f"Edge TTS Proxy 启动在 http://localhost:{port}")
    print(f"  POST /tts     — 文字转语音")
    print(f"  GET  /voices  — 语音列表")
    print(f"  GET  /health  — 健康检查")
    web.run_app(app, host="0.0.0.0", port=port)


if __name__ == "__main__":
    main()
