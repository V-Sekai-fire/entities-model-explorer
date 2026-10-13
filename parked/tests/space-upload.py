"""Upload the SkinTokens Space folder. The HF token comes on stdin (bao-hf-token | python3 this)."""
import sys
from huggingface_hub import HfApi

token = sys.stdin.read().strip()
api = HfApi(token=token)
info = api.upload_folder(
    repo_id="chibifire/skintokens-auto-rig",
    repo_type="space",
    folder_path=sys.argv[1],
    commit_message=sys.argv[2],
    ignore_patterns=["*.png", "*.py", "*.log", "godot/.gitkeep"],
    delete_patterns=["godot/*", "console/*"],
)
print(info.oid if hasattr(info, "oid") else info)
