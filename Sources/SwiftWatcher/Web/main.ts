import { AnsiUp } from "./ansi_up";

const ansi_up = new AnsiUp();
ansi_up.escape_html = true;
ansi_up.url_allowlist = { http: 1, https: 1 };

const current_path = window.location.pathname;
const ws_protocol = window.location.protocol === "https:" ? "wss:" : "ws:";

const ws_url = `${ws_protocol}//${window.location.host}${current_path}/ws`;
const socket = new WebSocket(ws_url);

const load_build_button = document.getElementById(
    "load-build-button",
)! as HTMLButtonElement;
load_build_button.addEventListener("click", () => {
    window.location.href = "/";
});

const log_container = document.getElementById(
    "log-container",
)! as HTMLDivElement;
const scrollToBottom = () => {
    log_container.scrollTop = log_container.scrollHeight;
};

// Set by buildResult; a socket close alone must not be read as success
let build_finished = false;

type StageState = "pending" | "running" | "success" | "failure";

const stage_el = (stage: number): HTMLDetailsElement | null =>
    document.getElementById(`stage-${stage}`) as HTMLDetailsElement | null;

const setStageState = (stage: number, state: StageState) => {
    const el = stage_el(stage);
    if (!el) return;
    el.classList.remove("pending", "running", "success", "failure");
    el.classList.add(state);
    el.open = state === "running" || state === "failure";
};

// The first stage is active as soon as the page loads.
setStageState(0, "running");

interface SocketMessage {
    type: "message" | "error" | "stageResult" | "buildResult";
    payload: string;
    stage: number;
    success?: boolean;
}

socket.onmessage = (event) => {
    const message: SocketMessage = JSON.parse(event.data);

    switch (message.type) {
        case "message": {
            const logs_elem = document.getElementById(
                `log-messages-${message.stage}`,
            ) as HTMLPreElement | null;
            if (logs_elem) {
                const html_payload = ansi_up.ansi_to_html(message.payload);
                logs_elem.insertAdjacentHTML("beforeend", html_payload + "\n");
            }
            scrollToBottom();
            break;
        }
        case "error": {
            const error_elem = document.getElementById(
                `log-error-${message.stage}`,
            ) as HTMLPreElement | null;
            if (error_elem) {
                error_elem.textContent += message.payload + "\n";
            }
            // Surface the failing stage immediately.
            setStageState(message.stage, "failure");
            scrollToBottom();
            break;
        }
        case "stageResult": {
            if (message.success) {
                setStageState(message.stage, "success");
                // Hand off to the next stage, if there is one.
                setStageState(message.stage + 1, "running");
            } else {
                setStageState(message.stage, "failure");
            }
            scrollToBottom();
            break;
        }
        case "buildResult": {
            build_finished = true;
            // Nothing should still be spinning once the build is over.
            document
                .querySelectorAll(".stage.running")
                .forEach((el) => el.classList.remove("running"));
            load_build_button.textContent = message.success
                ? "Build succeeded! Go to homepage…"
                : "Build failed. Return to previous homepage…";
            load_build_button.disabled = false;
            scrollToBottom();
            break;
        }
    }
};

socket.onclose = (_) => {
    if (build_finished) return;
    // Closed without a verdict: don't claim success.
    load_build_button.textContent = "Connection lost. Return to homepage…";
    load_build_button.disabled = false;
    scrollToBottom();
};
