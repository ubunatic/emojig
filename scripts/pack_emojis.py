import json
import struct
import os

def pack_emojis():
    json_path = "data/emoji.json"
    bin_path = "src/emojis.bin"

    print(f"Reading {json_path}...")
    with open(json_path, "r", encoding="utf-8") as f:
        emojis_data = json.load(f)

    string_table = bytearray()
    string_offsets = {}

    def get_or_add_string(s):
        s_bytes = s.encode("utf-8") + b"\x00"
        if s_bytes in string_offsets:
            return string_offsets[s_bytes]
        
        offset = len(string_table)
        string_table.extend(s_bytes)
        string_offsets[s_bytes] = offset
        return offset

    entries = []
    
    for item in emojis_data:
        emoji_char = item.get("emoji")
        description = item.get("description", "")
        tags = item.get("tags", [])
        aliases = item.get("aliases", [])

        if not emoji_char:
            continue

        # Build a search string containing unique words in lowercase
        search_words = []
        for word in description.lower().replace("-", " ").replace("_", " ").split():
            clean_word = "".join(c for c in word if c.isalnum())
            if clean_word and clean_word not in search_words:
                search_words.append(clean_word)
        
        for tag_or_alias in tags + aliases:
            for word in tag_or_alias.lower().replace("-", " ").replace("_", " ").split():
                clean_word = "".join(c for c in word if c.isalnum())
                if clean_word and clean_word not in search_words:
                    search_words.append(clean_word)

        search_str = " ".join(search_words)

        emoji_offset = get_or_add_string(emoji_char)
        name_offset = get_or_add_string(description)
        search_offset = get_or_add_string(search_str)

        entries.append({
            "emoji_offset": emoji_offset,
            "name_offset": name_offset,
            "search_offset": search_offset
        })

    emoji_count = len(entries)
    print(f"Packed {emoji_count} emojis.")

    index_size = emoji_count * 12
    header_size = 16
    
    string_table_offset = header_size + index_size

    header = struct.pack(
        "<4sHHII",
        b"EMJG",
        1,
        emoji_count,
        string_table_offset,
        len(string_table)
    )

    index_data = bytearray()
    for entry in entries:
        index_data.extend(struct.pack(
            "<III",
            entry["emoji_offset"],
            entry["name_offset"],
            entry["search_offset"]
        ))

    os.makedirs(os.path.dirname(bin_path), exist_ok=True)
    with open(bin_path, "wb") as f:
        f.write(header)
        f.write(index_data)
        f.write(string_table)

    total_size = len(header) + len(index_data) + len(string_table)
    print(f"Binary generated at {bin_path} ({total_size / 1024:.2f} KB).")

if __name__ == "__main__":
    pack_emojis()
