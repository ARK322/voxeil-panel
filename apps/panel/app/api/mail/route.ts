import { NextResponse } from "next/server";
import type { MailInfo } from "../../../src/lib/types";

export async function GET(): Promise<NextResponse<MailInfo>> {
  const mailInfo: MailInfo = {
    uiUrl: "https://mail.domain.com",
    status: "enabled",
    domains: [
      {
        domain: "example.com",
        mailboxesCount: 5,
        aliasesCount: 3,
      },
    ],
  };
  return NextResponse.json(mailInfo);
}
