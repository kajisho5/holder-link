"""Bundle ID を App Store Connect API で登録する（無ければ作る）。秘密の値は表示しない。

runway の scripts/asc.py（API の呼び出しと署名）を同じフォルダに置いて使う。
App Store Connect のアプリ記録は API では作れない（Apple が作成を許していない）ので、ここでは有無の確認だけ。
"""
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(__file__))
import asc  # noqa: E402

bundle_id = os.environ["BUNDLE_ID"]
name = os.environ.get("APP_NAME", "App")

q = urllib.parse.urlencode({"filter[identifier]": bundle_id, "limit": 200})
_, res = asc.api("GET", f"/v1/bundleIds?{q}")
found = [b for b in res.get("data", []) if b["attributes"].get("identifier") == bundle_id]
if found:
    print(f"Bundle ID {bundle_id} は登録済み（{found[0]['attributes'].get('platform')}）")
else:
    _, res = asc.api("POST", "/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
        "identifier": bundle_id, "name": name, "platform": "IOS"}}})
    print(f"Bundle ID {bundle_id} を登録した（id {res['data']['id']}）")

q = urllib.parse.urlencode({"filter[bundleId]": bundle_id})
_, res = asc.api("GET", f"/v1/apps?{q}")
if res.get("data"):
    print(f"App Store Connect のアプリ記録：あり（{res['data'][0]['attributes'].get('name')}）")
else:
    print("App Store Connect のアプリ記録：まだ無い（Web の画面で作る必要がある）")
