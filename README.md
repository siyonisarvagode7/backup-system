# backup-system
#  Automated Backup System with Screenshot Capture

##  Project Overview
The **Automated Backup System** is a Bash-based utility designed to simplify and automate the process of backing up important files and folders.  
It compresses data into `.tar.gz` archives, generates integrity checksums, maintains a smart backup rotation system (daily, weekly, and monthly), and logs every operation performed.  

In addition, this version integrates a **Python-based screenshot module**, which automatically captures a screenshot of the system when a backup completes.  
This helps in monitoring and validating the backup visually — ideal for audits, QA, and demonstrations.

---

##  Key Features

Feature  Description 

  **Automatic Backups**  Takes a folder as input and creates compressed backups with timestamped names. 

 **Lock File Mechanism**  Prevents multiple backup scripts from running simultaneously.

  **Checksum Verification**  Uses `sha256sum` to verify backup integrity and detect corruption. 

  **Smart Rotation**  Keeps 7 daily, 4 weekly, and 3 monthly backups — older ones are deleted automatically. 

  **Configuration File**  Allows users to modify backup destination, retention count, and exclusion patterns easily. 

  **Logging**  Every step is recorded in a `backup.log` file with timestamps and statuses. 

  **Dry Run Mode**  Simulates backup actions without making changes (for testing safely). 

  **Restore Option**  Restore any existing backup to a custom location. 

  **Screenshot Capture**  Automatically captures and saves a screenshot when a backup completes. 


---

##  Technologies Used

- **Bash Scripting** – Core backup automation logic  
- **Python 3** – For screenshot functionality  
- **tar**, **sha256sum** – For compression and verification  
- **pyautogui**, **pillow** – For capturing and saving screenshots  
- **Git** – For version control and deployment  

---



