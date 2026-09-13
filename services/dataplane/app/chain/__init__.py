"""碳權合約客戶端。deployments/local.json 不存在時必須 graceful degrade。"""

from app.chain.client import ChainClient

__all__ = ["ChainClient"]
