import ctypes


class HypergraphZError(Exception):
    pass


class NotBuiltError(HypergraphZError):
    pass


class VertexNotFoundError(HypergraphZError):
    pass


class HyperedgeNotFoundError(HypergraphZError):
    pass


class CycleDetectedError(HypergraphZError):
    pass


class NoPathError(HypergraphZError):
    pass


class IndexOutOfBoundsError(HypergraphZError):
    pass


class NotEnoughVerticesError(HypergraphZError):
    pass


_CODE_TO_EXC: dict[int, type[HypergraphZError]] = {
    -2: NotBuiltError,
    -3: VertexNotFoundError,
    -4: HyperedgeNotFoundError,
    -5: CycleDetectedError,
    -7: NoPathError,
    -8: IndexOutOfBoundsError,
    -9: NotEnoughVerticesError,
}


def raise_for_code(code: int, lib: ctypes.CDLL) -> None:
    """Raise the appropriate exception for a negative return code."""
    if code >= 0:
        return
    buf = ctypes.create_string_buffer(512)
    n = lib.hgz_last_error(buf, 512)
    msg = buf.raw[:n].decode("utf-8", errors="replace")
    exc_type = _CODE_TO_EXC.get(code, HypergraphZError)
    raise exc_type(msg)
