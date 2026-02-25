# OpenCode + Docker Compose + Docker Model Runner

## What this script does

This Python script starts a local development environment for the OpenCode project that is fully contained in a Docker Container.

## Prerequisites

- Docker and Docker Model Runner

## How to run the script

1. **Open a terminal** in the project root directory.
2. Run: `python3 init_opencode_docker_compose.py`
3. Follow the prompts (if applicable)
4. Once completed you should have two aliases available(`opencode-dc` and `opencode-dc-down`)
5. **Start OpenCode** by running:
   ```bash
   opencode-dc
   ```
   This command pulls the required Docker images, builds containers, and starts the services and models.
6. **Interact with the application**. You can now use the local instance of OpenCode.
7. **When finished**, exit the OpenCode session
8. **Shut down the environment** with:
   ```bash
   opencode-dc-down
   ```
   This will stop and remove the containers and stop Docker Model Runner, freeing system resources.

## Quick start

```bash
# 1️⃣ Install file
python3 init_opencode_docker_compose.py
# 2️⃣ Start
opencode-dc
# 3️⃣ Use the application
# 4️⃣ Stop
opencode-dc-down
```
