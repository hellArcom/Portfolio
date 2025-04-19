from googleapiclient.discovery import build
import json
import re
import time

def extract_channel_id(url, youtube):
    if "/channel/" in url:
        return url.split("/channel/")[1].split("/")[0]
    elif "/@" in url:
        try:
            username = url.split("/@")[1].split("/")[0]
            res = youtube.search().list(part="snippet", q=f"@{username}", type="channel", maxResults=1).execute()
            return res["items"][0]["snippet"]["channelId"] if res["items"] else None
        except:
            return None
    elif "/user/" in url:
        try:
            username = url.split("/user/")[1].split("/")[0]
            res = youtube.search().list(part="snippet", q=username, type="channel", maxResults=1).execute()
            return res["items"][0]["snippet"]["channelId"] if res["items"] else None
        except:
            return None
    return None

def get_all_video_ids(channel_id, youtube):
    video_ids = []
    request = youtube.search().list(
        part="id",
        channelId=channel_id,
        maxResults=50,
        order="date",
        type="video"
    )
    while request:
        response = request.execute()
        for item in response.get("items", []):
            video_ids.append(item["id"]["videoId"])
        request = youtube.search().list_next(request, response)
    return video_ids

def extract_info(video_id, youtube):
    res = youtube.videos().list(part="snippet", id=video_id).execute()
    if not res["items"]:
        return None

    snippet = res["items"][0]["snippet"]
    title = snippet.get("title", "")
    description = snippet.get("description", "")
    channel_title = snippet.get("channelTitle", "")
    tags = snippet.get("tags", [])

    emails = re.findall(r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}", description)
    urls = re.findall(r"(https?://[^\s]+)", description)

    return {
        "video_id": video_id,
        "titre": title,
        "pseudo": channel_title,
        "emails": list(set(emails)),
        "liens": list(set(urls)),
        "tags": tags
    }

def save_json(data, channel_name):
    filename = f"{channel_name.replace(' ', '_')}_data.json"
    try:
        with open(filename, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4, ensure_ascii=False)
        print(f"\n📁 Données enregistrées dans le fichier : {filename}")
    except Exception as e:
        print(f"\n❌ Erreur lors de la sauvegarde du fichier JSON : {e}")

def main():
    print("🎥 Nexolis – © Fait par Aylin \n")
    api_key = input("🔐 Entrez votre clé API YouTube : ").strip()
    youtube = build("youtube", "v3", developerKey=api_key)

    url = input("🔗 Entrez l'URL de la chaîne YouTube : ").strip()
    channel_id = extract_channel_id(url, youtube)

    if not channel_id:
        print("\n❌ Impossible de trouver l’ID de la chaîne.")
        return

    try:
        channel_info = youtube.channels().list(part="snippet", id=channel_id).execute()
        channel_name = channel_info["items"][0]["snippet"]["title"]
    except:
        print("❌ Impossible de récupérer le nom de la chaîne.")
        return

    print(f"\n📡 Chaîne détectée : {channel_name}")
    print("🔍 Récupération des vidéos...\n")
    video_ids = get_all_video_ids(channel_id, youtube)
    print(f"🎬 {len(video_ids)} vidéos trouvées.\n")

    results = []
    for idx, vid in enumerate(video_ids, 1):
        info = extract_info(vid, youtube)
        if info:
            results.append(info)
            print(f"✅ {info['titre']} a été crawlée. ({idx}/{len(video_ids)})")
        time.sleep(0.2)

    print("\n✅ Crawl terminé !")
    print("✋ Tapez la commande `/create file json` pour sauvegarder manuellement les données.")

    while True:
        cmd = input("\n💻 Commande : ").strip().lower()
        if cmd == "/create file json":
            save_json(results, channel_name)
            break
        else:
            print("❗Commande non reconnue. Tapez `/create file json` pour sauvegarder.")

    input("\n👋 Appuie sur Entrée pour quitter...")

if __name__ == "__main__":
    main()
    input("\nAppuie sur Entrée pour quitter...")