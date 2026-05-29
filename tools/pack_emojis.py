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
        # Normalize and convert to bytes with null-terminator
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
        # Add words from description
        for word in description.lower().replace("-", " ").replace("_", " ").split():
            clean_word = "".join(c for c in word if c.isalnum())
            if clean_word and clean_word not in search_words:
                search_words.append(clean_word)
        
        # Add tags and aliases
        for tag_or_alias in tags + aliases:
            for word in tag_or_alias.lower().replace("-", " ").replace("_", " ").split():
                clean_word = "".join(c for c in word if c.isalnum())
                if clean_word and clean_word not in search_words:
                    search_words.append(clean_word)

        search_str = " ".join(search_words)

        # Write to string table
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

    # Format of index entry: 3 x uint32 little-endian
    # total index size = emoji_count * 12 bytes
    index_size = emoji_count * 12
    header_size = 16 # 4 magic + 2 version + 2 count + 4 str_offset + 4 str_len
    
    string_table_offset = header_size + index_size

    # Build binary
    # Header:
    # magic: 4 bytes (EMJG)
    # version: uint16 (1)
    # count: uint16
    # string_table_offset: uint32
    # string_table_len: uint32
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
    print(f"String table size: {len(string_table) / 1024:.2f} KB (deduplicated).")

if __name__ == "__main__":
    pack_emojis()
