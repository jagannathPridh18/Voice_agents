import os

from sqlalchemy.ext.asyncio import create_async_engine
from sqlalchemy.orm import sessionmaker

DATABASE_URL = os.environ["DATABASE_URL"]

# Verbose SQL statement logging is useful locally but floods CloudWatch and
# hurts throughput in production. Enable it only when explicitly asked for via
# SQL_ECHO=true, or implicitly when LOG_LEVEL is DEBUG.
SQL_ECHO = os.getenv(
    "SQL_ECHO", "true" if os.getenv("LOG_LEVEL", "DEBUG").upper() == "DEBUG" else "false"
).lower() in ("1", "true", "yes")

engine = create_async_engine(DATABASE_URL, echo=SQL_ECHO)
async_session = sessionmaker(engine)
