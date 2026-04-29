"""
title: Summarise URL
description: Fetches a web page and asks the local n8n workflow to summarise it.
author: TBL4
version: 1.1
"""
import requests
from pydantic import BaseModel, Field


class Tools:
    class Valves(BaseModel):
        webhook_url: str = Field(
            # tbl4-ai-stack runs n8n in the same compose network, so OpenWebUI
            # reaches it at the service name. Override only if the n8n service
            # is renamed or you point this stack at a remote n8n.
            default="http://n8n:5678/webhook/summariseUrl/webhook/summarise-url",
            description="n8n webhook URL for the Summarise URL workflow.",
        )
        timeout_seconds: int = Field(
            default=60,
            description="How long to wait for the summary before giving up.",
        )

    def __init__(self):
        self.valves = self.Valves()

    def summarise_url(self, url: str, focus: str = "") -> str:
        """
        Summarise a web page.

        Call this whenever the user asks you to summarise, explain, or describe
        the content of a URL. Do not invent a summary — always call this tool.

        :param url: The web page to summarise. Must include https:// or http://.
        :param focus: Optional topic the summary should emphasise.
        :return: A short bullet-point summary of the page.
        """
        response = requests.post(
            self.valves.webhook_url,
            json={"url": url, "focus": focus},
            timeout=self.valves.timeout_seconds,
        )
        response.raise_for_status()
        return response.json().get("summary", "(no summary returned)")
