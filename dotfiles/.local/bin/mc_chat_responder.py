#!/usr/bin/env python3
import os
import sys
import time
import re
import json
import stat
import socket
import struct
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

# Global uinput is seat-wide. These checks reduce accidental targeting; the
# final focus-check -> injection interval remains a race, not window isolation.
class InputRefused(RuntimeError):
    pass


def _ipc_command(argv, env=None):
    try:
        result = subprocess.run(argv, capture_output=True, text=True, env=env,
                                timeout=3, check=False)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InputRefused('session/IPC command could not complete') from exc
    if result.returncode != 0:
        raise InputRefused('session/IPC command failed')
    return result.stdout


def _session_properties(session_id):
    output = _ipc_command(['loginctl', 'show-session', session_id, '--no-pager',
                          '--property=User', '--property=Active', '--property=Type',
                          '--property=Class', '--property=LockedHint', '--property=Scope'])
    return dict(line.split('=', 1) for line in output.splitlines() if '=' in line)


def _private_runtime(uid):
    path = f'/run/user/{uid}'
    item = os.lstat(path)
    if not stat.S_ISDIR(item.st_mode) or item.st_uid != uid or stat.S_IMODE(item.st_mode) != 0o700:
        raise InputRefused('runtime directory is not owned and private')
    return path


def _peer_process(pid):
    # Read only the identity fields needed for ownership; never log raw environ.
    with open(f'/proc/{pid}/stat') as stream:
        raw_stat = stream.read()
    start_time = raw_stat.rsplit(')', 1)[1].split()[19]
    with open(f'/proc/{pid}/cgroup') as stream:
        cgroup = stream.read()
    with open(f'/proc/{pid}/environ', 'rb') as stream:
        allowed = {'XDG_SESSION_ID', 'XDG_SESSION_TYPE', 'XDG_SESSION_CLASS'}
        identity = {}
        for part in stream.read().split(b'\0'):
            key, sep, value = part.partition(b'=')
            name = key.decode(errors='replace')
            if sep and name in allowed:
                identity[name] = value.decode(errors='replace')
    executable = os.path.basename(os.readlink(f'/proc/{pid}/exe'))
    return {'pid':pid, 'start_time':start_time, 'cgroup':cgroup,
            'identity':identity, 'executable':executable}


def _owned_compositor_ipc(path, runtime, uid, kind, session_id, scope):
    if not os.path.isabs(path) or os.path.normpath(path) != path or not path.startswith(runtime + '/'):
        raise InputRefused('compositor socket is outside the private runtime')
    relative = path[len(runtime)+1:].split('/')
    current = runtime
    for component in relative[:-1]:
        current = os.path.join(current, component)
        parent = os.lstat(current)
        if not stat.S_ISDIR(parent.st_mode) or parent.st_uid != uid or parent.st_mode & 0o022:
            raise InputRefused('compositor socket has an unsafe parent')
    item = os.lstat(path)
    if not stat.S_ISSOCK(item.st_mode) or item.st_uid != uid:
        raise InputRefused('compositor IPC is not an owned socket')
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(2)
        conn.connect(path)
        pid, peer_uid, _ = struct.unpack('3i', conn.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
    if peer_uid != uid or pid <= 0:
        raise InputRefused('compositor socket has a foreign peer')
    process = _peer_process(pid)
    if process['executable'] != kind:
        raise InputRefused('IPC peer is not the expected compositor')
    scoped = any(scope in line.split(':')[-1].split('/') for line in process['cgroup'].splitlines())
    if not scoped:
        # Niri can be owned by a user service instead of session-N.scope.
        # Require both its exact MainPID and explicit same-session identity.
        if kind != 'niri':
            raise InputRefused('compositor peer is outside the graphical session scope')
        unit = _ipc_command(['systemctl','--user','show','niri.service','--property=MainPID','--property=ActiveState','--property=ControlGroup'])
        props = dict(line.split('=',1) for line in unit.splitlines() if '=' in line)
        actual_group = next((line.split(':',2)[-1] for line in process['cgroup'].splitlines() if line.startswith('0::')), '')
        if (props.get('MainPID') != str(pid) or props.get('ActiveState') != 'active'
                or not actual_group or props.get('ControlGroup') != actual_group
                or process['identity'].get('XDG_SESSION_ID') != session_id
                or process['identity'].get('XDG_SESSION_TYPE') != 'wayland'):
            raise InputRefused('Niri service ownership cannot be tied to this session')
    after = os.lstat(path)
    if (after.st_dev, after.st_ino, after.st_uid) != (item.st_dev, item.st_ino, item.st_uid):
        raise InputRefused('compositor socket changed during ownership verification')
    return {'socket':path, 'device':item.st_dev, 'inode':item.st_ino,
            'pid':pid, 'start_time':process['start_time'], 'cgroup':process['cgroup']}


def resolve_action_session():
    uid = os.getuid()
    sessions = _ipc_command(['loginctl','list-sessions','--no-legend','--no-pager'])
    graphical = []
    for line in sessions.splitlines():
        fields = line.split()
        if len(fields) < 2:
            raise InputRefused('malformed logind session inventory')
        if fields[1] != str(uid):
            continue
        session_id = fields[0]
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', session_id):
            raise InputRefused('invalid logind session identity')
        props = _session_properties(session_id)
        if props.get('User') != str(uid) or not props.get('Type') or not props.get('Class'):
            raise InputRefused('logind session ownership query is incomplete')
        if props['Type'] in {'x11','wayland'} and props['Class'] == 'user':
            graphical.append((session_id, props))
    # Concurrent graphical sessions can share a uinput seat. Refuse rather
    # than selecting an arbitrary active/socket match.
    if len(graphical) != 1:
        raise InputRefused('a unique graphical session is required')
    session_id, props = graphical[0]
    if props.get('Active') != 'yes' or props.get('LockedHint') != 'no' or props['Type'] != 'wayland':
        raise InputRefused('graphical session is inactive, locked, or unsupported')
    scope = props.get('Scope', '')
    if scope != f'session-{session_id}.scope':
        raise InputRefused('graphical session scope could not be verified')
    output = _ipc_command(['systemctl','--user','show-environment'])
    manager = dict(line.split('=',1) for line in output.splitlines() if '=' in line)
    if (manager.get('XDG_SESSION_ID') != session_id or manager.get('XDG_SESSION_TYPE') != props['Type']
            or manager.get('XDG_SESSION_CLASS') != 'user'):
        raise InputRefused('user-manager graphical identity is stale or incomplete')
    desktop = manager.get('XDG_CURRENT_DESKTOP','').lower().split(':')
    supported = [kind for kind in ('niri','sway') if kind in desktop]
    if len(supported) != 1:
        raise InputRefused('this desktop has no verified Minecraft input adapter')
    kind = supported[0]
    runtime = _private_runtime(uid)
    if manager.get('XDG_RUNTIME_DIR') != runtime:
        raise InputRefused('user-manager runtime identity is inconsistent')
    wayland = manager.get('WAYLAND_DISPLAY', '')
    if not re.fullmatch(r'wayland-[A-Za-z0-9_.-]+', wayland):
        raise InputRefused('actual Wayland display name is missing or invalid')
    display_node = os.lstat(os.path.join(runtime, wayland))
    if not stat.S_ISSOCK(display_node.st_mode) or display_node.st_uid != uid:
        raise InputRefused('Wayland display is not an owned socket')
    ipc_key = 'NIRI_SOCKET' if kind == 'niri' else 'SWAYSOCK'
    path = manager.get(ipc_key, '')
    proof = _owned_compositor_ipc(path, runtime, uid, kind, session_id, scope)
    if _session_properties(session_id) != props:
        raise InputRefused('graphical session changed during verification')
    # Never reuse service-time display/socket defaults or import secret manager
    # variables. Construct only the documented graphical capability fields.
    env = {key:value for key,value in os.environ.items() if key not in
           {'DISPLAY','WAYLAND_DISPLAY','NIRI_SOCKET','SWAYSOCK','XDG_SESSION_ID','XDG_SESSION_TYPE','XDG_SESSION_CLASS','XDG_CURRENT_DESKTOP','XDG_RUNTIME_DIR'}}
    for key in ('XDG_SESSION_ID','XDG_SESSION_TYPE','XDG_SESSION_CLASS','XDG_CURRENT_DESKTOP','XDG_RUNTIME_DIR','WAYLAND_DISPLAY',ipc_key):
        env[key] = manager[key]
    return {'kind':kind,'session_id':session_id,'proof':proof,'env':env}


def _compositor_windows(context):
    kind, env = context['kind'], context['env']
    if kind == 'niri':
        value = json.loads(_ipc_command(['niri','msg','-j','windows'],env))
        if not isinstance(value,list) or not all(isinstance(row,dict) for row in value):
            raise InputRefused('malformed Niri windows response')
        return value
    tree = json.loads(_ipc_command(['swaymsg','-r','-t','get_tree'],env))
    if not isinstance(tree,dict):
        raise InputRefused('malformed Sway tree response')
    result = []
    def walk(node):
        if not isinstance(node,dict):
            raise InputRefused('malformed Sway tree node')
        properties = node.get('window_properties') or {}
        if not isinstance(properties,dict):
            raise InputRefused('malformed Sway window properties')
        if node.get('app_id') or properties.get('class'):
            result.append({'id':node.get('id'),'app_id':node.get('app_id') or properties.get('class'),
                           'pid':node.get('pid'),'is_focused':node.get('focused',False)})
        for key in ('nodes','floating_nodes'):
            children = node.get(key,[])
            if not isinstance(children,list):
                raise InputRefused('malformed Sway children')
            for child in children: walk(child)
    walk(tree)
    return result


def _minecraft_window(rows):
    matches = [row for row in rows if isinstance(row.get('app_id'),str) and
               re.fullmatch(r'(?:minecraft(?: [0-9][A-Za-z0-9. _-]*)?|net\.minecraft\.client\.main\.Main|com\.mojang\.minecraft)',row['app_id'],re.IGNORECASE)]
    if len(matches) != 1:
        raise InputRefused('an exact, unique Minecraft application window is required')
    target = matches[0]
    if type(target.get('id')) is not int or target['id'] <= 0:
        raise InputRefused('Minecraft window identity is invalid')
    return target


def _window_identity(row):
    return (row.get('id'),row.get('app_id'),row.get('pid'))


def _window_action(context, action, window_id):
    if type(window_id) is not int or window_id <= 0:
        raise InputRefused('invalid window-action target')
    if context['kind'] == 'niri':
        verb = 'focus-window' if action == 'focus' else 'close-window'
        _ipc_command(['niri','msg','action',verb,'--id',str(window_id)],context['env'])
    else:
        verb = 'focus' if action == 'focus' else 'kill'
        output = json.loads(_ipc_command(['swaymsg','-r',f'[con_id={window_id}] {verb}'],context['env']))
        if not isinstance(output,list) or len(output) != 1 or output[0].get('success') is not True:
            raise InputRefused('Sway rejected the exact window action')


def _fresh_focused_target(context, target):
    fresh = resolve_action_session()
    if (fresh['session_id'],fresh['kind'],fresh['proof']) != (context['session_id'],context['kind'],context['proof']):
        raise InputRefused('compositor/session identity changed before input')
    rows = _compositor_windows(fresh)
    actual = _minecraft_window(rows)
    focused = [row for row in rows if row.get('is_focused') is True]
    if _window_identity(actual) != _window_identity(target) or len(focused) != 1 or _window_identity(focused[0]) != _window_identity(target):
        raise InputRefused('Minecraft focus changed or could not be confirmed')
    return fresh


def _guarded_input(tokens, sent_text=None, close_after=False):
    try:
        context = resolve_action_session()
        rows = _compositor_windows(context)
        target = _minecraft_window(rows)
        previous = [row for row in rows if row.get('is_focused') is True]
        previous = previous[0] if len(previous) == 1 else None
        if not target.get('is_focused'):
            _window_action(context,'focus',target['id'])
            time.sleep(0.2)
        context = _fresh_focused_target(context,target)
        # One last fresh focus observation immediately before global input.
        context = _fresh_focused_target(context,target)
        result = subprocess.run([UINPUT_BIN,*tokens],env=context['env'],capture_output=True,
                                text=True,timeout=8,check=False)
        if result.returncode != 0:
            raise InputRefused('uinput command failed; input completion is unconfirmed')
        if sent_text is not None:
            record_bot_sent(sent_text)
        if close_after:
            context = _fresh_focused_target(context,target)
            _window_action(context,'close',target['id'])
        elif previous and _window_identity(previous) != _window_identity(target):
            # Do not steal focus if the operator switched windows mid-action.
            try:
                context = _fresh_focused_target(context,target)
                present = _compositor_windows(context)
                if any(_window_identity(row)==_window_identity(previous) for row in present):
                    _window_action(context,'focus',previous['id'])
            except (InputRefused,OSError,ValueError,KeyError,TypeError,IndexError,AttributeError,struct.error):
                logger.warning('Minecraft input completed; previous focus was not safely restored')
        return True
    except (InputRefused,OSError,ValueError,KeyError,TypeError,IndexError,AttributeError,struct.error,subprocess.TimeoutExpired) as exc:
        logger.warning('Minecraft action refused or incomplete: %s',exc)
        return False


def send_command(command: str):
    cmd_name = command.lstrip('/')
    if not cmd_name:
        return False
    return _guarded_input(['slash','sleep:250',f'type:{cmd_name}','sleep:250','enter','sleep:200'],f'/{cmd_name}')


def send_chat(reply: str):
    if not reply or reply.upper() == 'IGNORE':
        return False
    return _guarded_input(['t','sleep:250',f'type:{reply}','sleep:250','enter','sleep:200'],reply)


def execute_jump():
    return _guarded_input(['type: ','sleep:200'])


def execute_logoff(sender: str):
    if not is_authorized_to_logoff(sender):
        logger.warning('Unauthorized logoff attempt blocked')
        return False
    if not _guarded_input(['slash','sleep:250','type:disconnect','sleep:250','enter','sleep:200'], '/disconnect', close_after=True):
        return False
    # Only stop this helper after the exact game-window close was accepted.
    try:
        _ipc_command(['systemctl','--user','stop','mc-chat-responder.service'])
    except InputRefused as exc:
        logger.warning('Minecraft logoff completed; responder stop was not confirmed: %s',exc)
        return False
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
                    if send_command("tpaccept"):
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
                    if send_chat(clean_reply):
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
