import QtQuick
import qs.Common

QtObject {
    function check(done) {
        Proc.runCommand("npuAssistant.depCheck", ["sh", "-c", "command -v curl && curl -s --max-time 2 http://127.0.0.1:8737/status"], (stdout, exitCode) => {
            if (exitCode === 0) {
                done(null);
                return;
            }
            done({
                "title": I18n.trFor("npuAssistant", "The assistant service is not running"),
                "details": I18n.trFor("npuAssistant", "The plugin talks to a local backend that runs the model on the NPU. Install it with backend/install.sh from the plugin folder (needs a Python environment with openvino_genai), then re-enable the plugin.")
            });
        });
    }
}
