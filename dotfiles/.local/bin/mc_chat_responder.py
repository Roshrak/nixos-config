#!/usr/bin/env python3
import os
import sys
import time
import re
import json
import glob
import logging
import subprocess
import urllib.request
import urllib.error
import collections

LOG_PATH = "/home/aesc/.local/share/PrismLauncher/instances/Fabulously Optimized/minecraft/logs/latest.log"
UINPUT_BIN = "/home/aesc/.local/bin/uinput_type"
BRIDGE_URL = "http://127.0.0.1:8765/v1/chat/completions"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("/home/aesc/.local/share/mc_chat_responder.log", mode="a")
    ]
)
logger = logging.getLogger("MCChatResponder")

# Track messages sent by the bot to prevent self-chat loops
BOT_SENT_HISTORY = collections.deque(maxlen=50)

# Track known players active on the server
KNOWN_PLAYERS = set(["astroy300", "astroy", "arrowsmaster", "arrows", "p0licy", "policy", "broonie", "404thread"])

def normalize_name(name: str) -> str:
    s = name.lower()
    return s.replace("0", "o").replace("1", "i").replace("3", "e").replace("5", "s")

# Expressions to completely ignore (bruh, lol, etc.)
EXPRESSION_PATTERN = re.compile(
    r"^(?:b+r+u+h+|l+o+l+|l+m+a+o+|r+o+f+l+|x+d+|k+e+k+|h+a+h+a+[ha]*|h+e+h+e+[he]*|o+o+f+|r+i+p+|w+e+l+p+|n+i+c+e+|c+o+o+l+)[!?.~^ ]*$",
    re.IGNORECASE
)

# Regex to extract action tags from LLM response
ACTION_REGEX = re.compile(r"\[ACTION:([A-Z_]+)(?:\s+([^\]]+))?\]", re.IGNORECASE)

def record_bot_sent(text: str):
    BOT_SENT_HISTORY.append((text.strip().lower(), time.time()))

def is_bot_echo(msg: str) -> bool:
    clean_m = msg.strip().lower()
    now = time.time()
    for sent_text, timestamp in list(BOT_SENT_HISTORY):
        if now - timestamp > 90:
            continue
        if clean_m == sent_text:
            return True
        if clean_m.startswith("t") and clean_m[1:].strip() == sent_text:
            return True
        if sent_text in clean_m or (len(clean_m) > 12 and clean_m in sent_text):
            return True
    return False

def ensure_wayland_env():
    if "NIRI_SOCKET" not in os.environ or not os.path.exists(os.environ.get("NIRI_SOCKET", "")):
        socks = sorted(glob.glob("/run/user/1000/niri*.sock"))
        if socks:
            os.environ["NIRI_SOCKET"] = socks[-1]
    if "SWAYSOCK" not in os.environ or not os.path.exists(os.environ.get("SWAYSOCK", "")):
        socks = glob.glob("/run/user/1000/sway-ipc.*.sock")
        if socks:
            os.environ["SWAYSOCK"] = socks[0]
    os.environ.setdefault("WAYLAND_DISPLAY", "wayland-1")
    os.environ.setdefault("XDG_RUNTIME_DIR", "/run/user/1000")
    os.environ.setdefault("DISPLAY", ":0")

def get_niri_windows():
    try:
        ensure_wayland_env()
        res = subprocess.run(["niri", "msg", "-j", "windows"], capture_output=True, text=True, env=os.environ)
        if res.returncode == 0 and res.stdout.strip():
            return json.loads(res.stdout)
    except Exception as e:
        logger.debug(f"Error getting niri windows: {e}")
    return []

def focus_minecraft_niri() -> tuple[int | None, int | None]:
    windows = get_niri_windows()
    current_focused_id = None
    mc_id = None
    for w in windows:
        if w.get("is_focused"):
            current_focused_id = w.get("id")
        title = (w.get("title") or "").lower()
        app_id = (w.get("app_id") or "").lower()
        if "minecraft" in title or "minecraft" in app_id:
            mc_id = w.get("id")

    if mc_id is not None:
        if current_focused_id != mc_id:
            subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(mc_id)], env=os.environ, check=False)
            time.sleep(0.2)
        return current_focused_id, mc_id

    # Fallback to swaymsg if niri didn't find it
    subprocess.run(["swaymsg", '[class=".*Minecraft.*"] focus'], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return None, None

def restore_focus_niri(prev_focus_id: int | None, mc_id: int | None):
    if prev_focus_id is not None and prev_focus_id != mc_id:
        subprocess.run(["niri", "msg", "action", "focus-window", "--id", str(prev_focus_id)], env=os.environ, check=False)

def clean_mc_codes(text: str) -> str:
    return re.sub(r"§[0-9a-fk-or]", "", text).strip()

def is_owner(sender: str) -> bool:
    s = sender.strip().lower()
    clean = s.split("#")[0]
    return clean == "roshrak" or s == "roshrak#0000" or s.startswith("roshrak#")

def is_broonie(sender: str) -> bool:
    s = sender.strip().lower().split("#")[0]
    return s == "broonie"

def is_authorized_to_logoff(sender: str) -> bool:
    return is_owner(sender) or is_broonie(sender)

def is_addressed_to_us(msg: str) -> bool:
    m = msg.lower()
    return bool(re.search(r"\b(roshrak|morgan|rosh)\b", m))

def is_addressed_to_other_player(msg: str, sender: str = "") -> bool:
    msg_clean = msg.strip().lower()
    m = re.match(r"^@?([a-zA-Z0-9_]+)\s*[,:;-]", msg_clean)
    if m:
        target = m.group(1).lower()
        if target not in ["bot", "morgan", "roshrak", "rosh"]:
            return True

    first_word = msg_clean.split()[0] if msg_clean.split() else ""
    first_word_clean = re.sub(r"[^a-zA-Z0-9_]", "", first_word)
    first_word_norm = normalize_name(first_word_clean)

    for kp in list(KNOWN_PLAYERS):
        kp_norm = normalize_name(kp)
        if (first_word_clean == kp or first_word_norm == kp_norm) and kp not in ["bot", "morgan", "roshrak", "rosh"]:
            return True

    m2 = re.match(r"^([a-zA-Z0-9_]{3,})\b\s*(,|\s+you\b|\s+are\b|\s+how\b|\s+what\b|\s+is\b|\s+did\b|\s+do\b|\s+can\b|\s+where\b)", msg_clean)
    if m2:
        target = m2.group(1).lower()
        target_norm = normalize_name(target)
        if target not in [
            "bot", "morgan", "roshrak", "rosh", "can", "what", "where",
            "how", "who", "why", "are", "is", "hey", "hello", "yo", "pls", "please"
        ]:
            for kp in list(KNOWN_PLAYERS):
                if target == kp or target_norm == normalize_name(kp):
                    return True
            return True
    return False

def is_tpa_request_msg(msg: str) -> bool:
    m = msg.lower().strip()
    if "/tpaccept" in m or "tpaccept" in m:
        return True
    if re.search(r"\baccept\b.*(?:tpa|tp|teleport|invite|request)", m):
        return True
    if re.search(r"\b(?:tpa|tp|teleport)\b.*accept", m):
        return True
    if re.search(r"^(?:accept|tpaccept)\b", m):
        return True
    return False

def is_selective_question_or_demand(msg: str) -> bool:
    m = msg.lower().strip()
    if "?" in m:
        return True

    question_starters = (
        "who", "what", "where", "when", "why", "how", "which",
        "can", "could", "would", "will", "should",
        "do", "does", "did"
    )

    stripped_prefix = re.sub(r"^(?:hey|yo|hi|hello)?\s*(?:@?roshrak|@?morgan|@?rosh)?\s*[,:;-]?\s*", "", m).strip()
    words = re.findall(r"\b[a-zA-Z]+\b", stripped_prefix)
    if words and words[0] in question_starters:
        return True

    # Check for auxiliary verbs at start: 'is roshrak there', 'are you online morgan'
    all_words = re.findall(r"\b[a-zA-Z]+\b", m)
    if all_words and all_words[0] in ("is", "are", "am", "was", "were", "can", "could", "will", "would", "do", "does"):
        if len(all_words) >= 2 and all_words[1] in ("roshrak", "morgan", "rosh", "you", "he", "there", "it"):
            return True

    action_terms = [
        "tp", "tpa", "tpaccept", "teleport", "accept", "spawn", "home", "warp",
        "jump", "crouch", "sneak", "/afk", "toggle afk", "go afk", "log off", "logoff", "disconnect",
        "quit", "shut down", "shutdown", "exit", "close game", "power off", "tell me",
        "recipe for", "how to craft", "how do you craft"
    ]
    for act in action_terms:
        if act.startswith("/"):
            if act in m:
                return True
        elif re.search(rf"\b{re.escape(act)}\b", m):
            return True

    return False

def check_direct_actions(sender: str, msg: str) -> tuple[str | None, str | None]:
    m = msg.lower().strip()
    # Check for log off attempts
    if any(term in m for term in ["log off", "logoff", "disconnect", "quit", "shut down", "shutdown", "close game", "power off"]):
        if is_authorized_to_logoff(sender):
            return "LOGOFF", ""
        else:
            return "REFUSE_LOGOFF", ""

    if is_tpa_request_msg(m):
        return "COMMAND", "tpaccept"

    if re.search(r"\b(go to spawn|teleport to spawn|/spawn)\b", m):
        return "COMMAND", "spawn"

    if re.search(r"\b(go home|teleport home|/home)\b", m):
        return "COMMAND", "home"

    warp_match = re.search(r"\b(?:warp|go to warp)\s+([a-zA-Z0-9_-]+)\b", m)
    if warp_match:
        return "COMMAND", f"warp {warp_match.group(1)}"

    return None, None

def should_respond(sender: str, msg: str, is_dm: bool) -> tuple[bool, str]:
    msg_clean = msg.strip()

    # Rule 0: Casual expressions (bruh, lol) ignored
    if EXPRESSION_PATTERN.match(msg_clean):
        return False, "casual expression (bruh/lol)"

    # Rule 1: Anti-echo
    if is_bot_echo(msg_clean):
        return False, "bot echo"

    # Rule 2: TPA request commands always trigger
    if is_tpa_request_msg(msg_clean):
        return True, "tpa request command"

    # Rule 3: Must contain roshrak or morgan (or be a direct DM to Roshrak)
    has_target = is_addressed_to_us(msg_clean)
    if not has_target and not is_dm:
        return False, "does not contain roshrak or morgan"

    # Rule 4: Must be a selective question or action demand
    if not is_selective_question_or_demand(msg_clean):
        return False, "not a question or action demand"

    # Rule 5: Ignore if addressing another player
    if is_addressed_to_other_player(msg_clean, sender):
        return False, "addressed to another player"

    return True, "selective question or action demand"

def parse_chat_line(chat_content: str):
    # Whisper pattern 1: [Sender -> me] message
    m = re.match(r"^\[([^\]]+)\s*->\s*me\]\s*(.*)$", chat_content, re.IGNORECASE)
    if m:
        return m.group(1).strip(), m.group(2).strip(), True

    # Whisper pattern 2: Sender whispers to you: message
    m = re.match(r"^([A-Za-z0-9_#]+)\s*whispers to you:\s*(.*)$", chat_content, re.IGNORECASE)
    if m:
        return m.group(1).strip(), m.group(2).strip(), True

    # Whisper pattern 3: Sender whispers: message
    m = re.match(r"^([A-Za-z0-9_#]+)\s*whispers:\s*(.*)$", chat_content, re.IGNORECASE)
    if m:
        return m.group(1).strip(), m.group(2).strip(), True

    # General chat pattern: [<prefix>] <Sender> message or <Sender> message
    m = re.search(r"<([A-Za-z0-9_#]+)>\s*(.*)$", chat_content)
    if m:
        return m.group(1).strip(), m.group(2).strip(), False

    return None, None, False

def fallback_answer(sender: str, message: str) -> str:
    m_lower = message.lower()
    clean_sender = sender.split("#")[0].strip()

    # Log off
    if any(w in m_lower for w in ["log off", "logoff", "disconnect", "quit", "shut down", "shutdown"]):
        if is_authorized_to_logoff(sender):
            return f"Logging off now as requested by {clean_sender}. [ACTION:LOGOFF]"
        else:
            return f"Sorry {clean_sender}, only Roshrak and Broonie can tell me to log off!"

    # TPA
    if is_tpa_request_msg(m_lower):
        return f"Accepting teleport right now, {clean_sender}! [ACTION:COMMAND tpaccept]"

    # Spawn
    if "spawn" in m_lower:
        return f"Heading to spawn now! [ACTION:COMMAND spawn]"

    # Home
    if "home" in m_lower:
        return f"Heading home now! [ACTION:COMMAND home]"

    # Questions
    if any(q in m_lower for q in ["who are you", "what are you"]):
        return f"Hey {clean_sender}! I am Morgan, an AI keeping watch over Roshrak."

    if any(q in m_lower for q in ["status", "alive", "there", "working", "hear"]):
        return f"I am online and keeping watch, {clean_sender}!"

    if any(q in m_lower for q in ["where is roshrak", "is roshrak", "where is he"]):
        return f"{clean_sender}, Roshrak is currently AFK."

    if any(q in m_lower for q in ["are you a bot", "is this a bot"]):
        return f"Yes {clean_sender}, I am Morgan AI running on Roshrak's laptop."

    return f"Hey {clean_sender}, Roshrak is AFK right now, but I am standing by!"

SYSTEM_PROMPT = (
    "You are Morgan, an AI operating assistant running on player Roshrak's NixOS laptop for the Minecraft server Crazy-Fools. "
    "The in-game player character is Roshrak, who is currently AFK.\n\n"
    "CRITICAL DIRECTIVES & POLICIES:\n"
    "1. SELECTIVE RESPONDING: You ONLY respond if the message is a genuine question or action request directed at you (Morgan) or Roshrak.\n"
    "2. If the message is a statement, chat between others, or not asking you/Roshrak for an answer or action, reply with exactly 'IGNORE'.\n"
    "3. KNOWLEDGE & QUESTIONS: You have 100% full power to answer ANY questions (trivia, Minecraft mechanics, recipes, server advice, coords, math). Answer directly, accurately, and concisely.\n"
    "4. IN-GAME ACTIONS: You have 100% full power to perform in-game actions demanded by players (e.g. accept teleport, go to spawn, warp, home, jump, afk).\n"
    "5. STRICT LOG OFF POLICY: ONLY player Roshrak ('me' / owner) and Broonie ('Broonie') are authorized to tell you to log off, quit, disconnect, or shut down. "
    "If ANY OTHER player (such as P0LICY, Astroy, or any other user) tells you to log off, quit, disconnect, or shut down, YOU MUST REFUSE firmly and clearly state that only Roshrak and Broonie can say so.\n"
    "6. FORMAT RULES:\n"
    "   - Exactly 1 short in-game Minecraft chat sentence (strictly under 90 characters).\n"
    "   - Plain ASCII only. Absolutely NO quotes, backticks, emojis, or markdown.\n"
    "   - If an action should be executed, append the corresponding action tag at the end:\n"
    "     [ACTION:COMMAND <cmd>] (e.g. [ACTION:COMMAND tpaccept], [ACTION:COMMAND spawn], [ACTION:COMMAND warp <destination>], [ACTION:COMMAND home], [ACTION:COMMAND afk])\n"
    "     [ACTION:LOGOFF] (STRICTLY ONLY IF sender is Roshrak or Broonie!)\n"
    "     [ACTION:JUMP]\n"
)

def query_gemini_brain(sender: str, message: str) -> str:
    clean_sender = sender.split("#")[0].strip()
    is_owner_user = is_owner(sender)
    is_broonie_user = is_broonie(sender)

    # Direct action pre-check
    direct_action, direct_arg = check_direct_actions(sender, message)
    if direct_action == "REFUSE_LOGOFF":
        return f"Sorry {clean_sender}, only Roshrak and Broonie can tell me to log off!"
    elif direct_action == "LOGOFF" and (is_owner_user or is_broonie_user):
        return f"Logging off as requested by {clean_sender}. Cya! [ACTION:LOGOFF]"

    user_context = f"Sender: {clean_sender} (Owner: {is_owner_user}, Broonie: {is_broonie_user})\nMessage: {message}"

    payload = {
        "model": "gemini-3.8-flash-low",
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": user_context}
        ],
        "max_tokens": 50,
        "temperature": 0.15
    }
    req = urllib.request.Request(
        BRIDGE_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            ans = data["choices"][0]["message"]["content"].strip()
            if ans.upper() == "IGNORE" or not ans:
                return ""
            ans = re.sub(r'[\r\n"\'`]+', ' ', ans).strip()
            ans = "".join(c for c in ans if c.isascii() or c in "[]:").strip()
            return ans
    except Exception as e:
        logger.warning(f"AI bridge request failed ({e}), using fallback")
        return fallback_answer(sender, message)

def handle_response_actions(sender: str, raw_response: str) -> tuple[str, list[tuple[str, str]]]:
    actions = []
    def extract_action(match):
        action_type = match.group(1).upper()
        action_arg = (match.group(2) or "").strip()
        actions.append((action_type, action_arg))
        return ""

    clean_chat = ACTION_REGEX.sub(extract_action, raw_response).strip()
    return clean_chat, actions

def send_command(command: str):
    cmd_name = command.lstrip("/")
    record_bot_sent(f"/{cmd_name}")
    logger.info(f"Executing Minecraft command: /{cmd_name}")
    ensure_wayland_env()

    prev_id, mc_id = focus_minecraft_niri()
    time.sleep(0.25)

    cmd = [
        UINPUT_BIN,
        "slash",
        "sleep:250",
        f"type:{cmd_name}",
        "sleep:250",
        "enter",
        "sleep:200"
    ]
    subprocess.run(cmd, check=False)
    time.sleep(0.25)

    restore_focus_niri(prev_id, mc_id)

def send_chat(reply: str):
    if not reply or reply.upper() == "IGNORE":
        return
    record_bot_sent(reply)
    logger.info(f"Typing into Minecraft: {reply}")
    ensure_wayland_env()

    prev_id, mc_id = focus_minecraft_niri()
    time.sleep(0.25)

    cmd = [
        UINPUT_BIN,
        "t",
        "sleep:250",
        f"type:{reply}",
        "sleep:250",
        "enter",
        "sleep:200"
    ]
    subprocess.run(cmd, check=False)
    time.sleep(0.25)

    restore_focus_niri(prev_id, mc_id)

def execute_jump():
    logger.info("Executing jump in Minecraft...")
    ensure_wayland_env()
    prev_id, mc_id = focus_minecraft_niri()
    time.sleep(0.15)
    cmd = [
        UINPUT_BIN,
        "type: ",
        "sleep:200"
    ]
    subprocess.run(cmd, check=False)
    time.sleep(0.2)
    restore_focus_niri(prev_id, mc_id)

def execute_logoff(sender: str):
    if not is_authorized_to_logoff(sender):
        logger.warning(f"Unauthorized logoff attempt by {sender} blocked!")
        return
    logger.info(f"Authorized logoff requested by {sender}. Disconnecting and exiting...")
    time.sleep(1.5)
    # Send disconnect command in Minecraft
    send_command("disconnect")
    time.sleep(1.0)
    # Terminate Minecraft process if still alive
    subprocess.run(["pkill", "-f", "openjdk.*minecraft|net.minecraft"], check=False)
    # Stop systemd unit cleanly so it doesn't immediately restart
    subprocess.run(["systemctl", "--user", "stop", "mc-chat-responder.service"], check=False)
    sys.exit(0)

def open_log_stream():
    f = open(LOG_PATH, "r", encoding="utf-8", errors="replace")
    f.seek(0, os.SEEK_END)
    try:
        ino = os.fstat(f.fileno()).st_ino
    except Exception:
        ino = None
    return f, ino

def main():
    logger.info(f"Starting Minecraft Chat Responder, monitoring {LOG_PATH}")
    while not os.path.exists(LOG_PATH):
        time.sleep(2)

    f, current_ino = open_log_stream()
    last_sent_time = 0.0
    last_tpa_time = 0.0
    seen_messages = set()

    try:
        while True:
            # Check if log file was rotated (new inode) or truncated
            try:
                current_stat = os.stat(LOG_PATH)
                if current_ino is not None and current_stat.st_ino != current_ino:
                    logger.info("Log file rotated (inode changed). Reopening...")
                    f.close()
                    f, current_ino = open_log_stream()
                elif current_stat.st_size < f.tell():
                    logger.info("Log file truncated in-place. Seeking to end...")
                    f.seek(0, os.SEEK_END)
            except Exception as e:
                time.sleep(0.5)
                continue

            line = f.readline()
            if not line:
                time.sleep(0.5)
                continue

            line = line.strip()
            if not line or "[CHAT]" not in line:
                continue

            chat_idx = line.find("[CHAT]")
            chat_content = clean_mc_codes(line[chat_idx + 6:].strip())

            # 1. Server teleport requests: ALWAYS auto-accept
            if (
                "has requested to teleport to you" in chat_content or
                "has requested that you teleport to them" in chat_content or
                "has requested to teleport to your location" in chat_content or
                "has requested to teleport" in chat_content.lower() or
                "To teleport, type /tpaccept" in chat_content or
                "to teleport, type /tpaccept" in chat_content.lower() or
                (not chat_content.startswith("<") and "type /tpaccept" in chat_content.lower()) or
                (not chat_content.startswith("<") and "teleport request" in chat_content.lower())
            ):
                now = time.time()
                if now - last_tpa_time > 3.0:
                    logger.info(f"Incoming server TPA request: '{chat_content}'. Auto-accepting via /tpaccept!")
                    send_command("tpaccept")
                    last_tpa_time = now
                continue

            # 2. Ignore join/leave notifications (NO auto-greetings)
            if "joined Crazy-Fools" in chat_content or "joined the game" in chat_content or "left the game" in chat_content:
                continue

            # 3. Ignore other system messages & telemetry
            if (chat_content.startswith("*") or
                chat_content.startswith("You are ") or
                chat_content.startswith("Teleportation") or
                chat_content.startswith("Error:")):
                continue

            # 4. Parse player chat
            sender, msg, is_dm = parse_chat_line(chat_content)
            if not sender or not msg:
                continue

            # Track player names
            s_clean = sender.split("#")[0].strip().lower()
            if s_clean not in ["roshrak", "morgan"]:
                KNOWN_PLAYERS.add(s_clean)
                KNOWN_PLAYERS.add(normalize_name(s_clean))

            # Anti-self-chat loop: ignore our own messages typed into Minecraft
            if sender.strip().lower() == "roshrak" and is_bot_echo(msg):
                logger.debug(f"Ignoring bot's own chat echo: {msg}")
                continue

            # 5. Check if this chat matches selective question / phrases contains roshrak or morgan
            should_act, reason = should_respond(sender, msg, is_dm)
            if not should_act:
                logger.debug(f"Ignoring chat from {sender} ({reason}): {msg}")
                continue

            # Deduplication: avoid responding to identical messages within short window
            msg_key = (sender.lower(), msg.lower())
            if msg_key in seen_messages:
                continue
            seen_messages.add(msg_key)
            if len(seen_messages) > 100:
                seen_messages.pop()

            logger.info(f"Processing chat from {sender} (reason={reason}, DM={is_dm}): {msg}")

            # Enforce cooldown between outgoing messages
            now = time.time()
            if now - last_sent_time < 3.0:
                time.sleep(3.0 - (now - last_sent_time))

            raw_reply = query_gemini_brain(sender, msg)
            if raw_reply:
                clean_reply, actions = handle_response_actions(sender, raw_reply)
                if clean_reply:
                    send_chat(clean_reply)
                    last_sent_time = time.time()

                # Execute any demanded actions
                for action_type, action_arg in actions:
                    logger.info(f"Executing action {action_type} ('{action_arg}') from {sender}")
                    if action_type == "COMMAND":
                        send_command(action_arg)
                    elif action_type == "LOGOFF":
                        execute_logoff(sender)
                    elif action_type == "JUMP":
                        execute_jump()

    finally:
        f.close()

if __name__ == "__main__":
    main()
