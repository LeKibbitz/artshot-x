"""Real ScreenCaptureKit start/pause/resume/stop/native MP4 export smoke."""
import json
import subprocess
import tempfile
import time
from pathlib import Path

helper = Path(__file__).resolve().parents[1] / "native/macos/artshot-native"
folder = Path(tempfile.mkdtemp(prefix="artshot-native-recording-"))
process = subprocess.Popen([str(helper)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
def request(action, **options):
    process.stdin.write(json.dumps(dict(action=action, **options)) + "\n")
    process.stdin.flush()
    response = json.loads(process.stdout.readline())
    if not response.get("ok"):
        raise RuntimeError(response)
    return response
try:
    request("start", displayId=1, directory=str(folder), region=dict(x=0,y=0,width=640,height=360), systemAudio=True)
    time.sleep(1)
    request("pause")
    time.sleep(0.5)
    request("resume")
    time.sleep(1)
    recording = request("stop")
    assert 1.5 < recording["duration"] < 2.5, recording
    output = folder / "export.mp4"
    request("export", path=recording["path"], destination=str(output))
    result = request("inspect", path=str(output))
    assert output.stat().st_size > 1000
    print(json.dumps(result))
finally:
    process.stdin.close()
    process.wait(timeout=5)
