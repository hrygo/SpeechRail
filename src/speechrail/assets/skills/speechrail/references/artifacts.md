# Artifact handling

Audio and job results are files on the MCP host. A path is not portable across
hosts; if the MCP proxy is remote, ask for an artifact transfer boundary
instead of guessing that the agent can open the path. Keep the returned media
type, byte count, and revision metadata with the artifact.

Inspect existence and size before handing a file to the next local step. Do
not read an entire audio file into context. Retain files only for the user's
requested workflow; clean up only exact temporary paths created by the
current tool call, never a directory or a user-provided source file.

For transcription results, prefer the materialized JSON artifact. For speech,
play or pass the audio file through the host's media path. A successful tool
response means a file was materialized, not that a downstream video or edit
pipeline has accepted it.
