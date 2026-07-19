import { execFile } from "node:child_process";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export async function runCommand(
  executable,
  args,
  { allowedExitCodes = [0] } = {},
) {
  try {
    const { stdout = "", stderr = "" } = await execFileAsync(
      executable,
      args,
      {
        encoding: "utf8",
        maxBuffer: 2 * 1024 * 1024,
      },
    );
    return { stdout, stderr, exitCode: 0 };
  } catch (error) {
    const exitCode = Number.isInteger(error?.code) ? error.code : null;
    if (exitCode !== null && allowedExitCodes.includes(exitCode)) {
      return {
        stdout: error.stdout ?? "",
        stderr: error.stderr ?? "",
        exitCode,
      };
    }

    const detail = String(error?.stderr ?? error?.message ?? error).trim();
    const commandName = executable.split("/").at(-1);
    throw new Error(`${commandName} failed${detail ? `: ${detail}` : ""}`);
  }
}
