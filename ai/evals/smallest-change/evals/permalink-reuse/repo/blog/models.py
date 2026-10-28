from dataclasses import dataclass
from datetime import date

from blog.text import truncate


@dataclass
class Post:
    title: str
    published: date
    body: str

    @property
    def excerpt(self):
        return truncate(self.body, 140)
