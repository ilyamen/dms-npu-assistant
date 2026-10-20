"""Image hook. Qwen3-4B has no vision, so images are not handled yet.

TODO: plug in a VLM here — a cloud API or a local one (e.g. Qwen2.5-VL / Phi-3.5-vision through
openvino_genai.VLMPipeline on the iGPU or NPU). describe() should return a text description that the
server prepends to the user's message, so the text model can answer about the picture.
"""


class NotSupported(Exception):
    pass


def describe(image_b64, mime, question):
    raise NotSupported("Картинки пока не поддерживаются")
