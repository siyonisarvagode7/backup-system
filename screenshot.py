import pyautogui
import os
from datetime import datetime

# Folder to save screenshots
screenshot_dir = "backups/screenshots"

# Create the directory if it doesn't exist
os.makedirs(screenshot_dir, exist_ok=True)

# Generate a filename with timestamp
timestamp = datetime.now().strftime("%Y-%m-%d-%H%M%S")
filename = f"screenshot-{timestamp}.png"
filepath = os.path.join(screenshot_dir, filename)

# Take and save screenshot
try:
    image = pyautogui.screenshot()
    image.save(filepath)
    print(f"✅ Screenshot saved: {filepath}")
except Exception as e:
    print(f"❌ Failed to take screenshot: {e}")

