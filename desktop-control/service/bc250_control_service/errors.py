class ServiceError(RuntimeError):
    """Base error that can safely be returned over D-Bus."""


class InvalidArguments(ServiceError):
    pass


class AccessDenied(ServiceError):
    pass


class OperationNotFound(ServiceError):
    pass
