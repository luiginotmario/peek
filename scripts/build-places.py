"""turns the geonames dump into App/places.json, the offline place list peek searches against.

    curl -O https://download.geonames.org/export/dump/cities15000.zip && unzip cities15000.zip
    curl -O https://download.geonames.org/export/dump/admin1CodesASCII.txt
    curl -O https://download.geonames.org/export/dump/countryInfo.txt
    python3 -I scripts/build-places.py <folder with those files> App/places.json

the dump is treated as untrusted input: only plain names, numbers and codes survive, every
field is validated, and anything that doesn't fit is dropped. the output is data only; peek never
executes it. geonames.org, CC-BY 4.0.
"""

import json
import re
import sys
from pathlib import Path

NAME = re.compile(r"^[A-Za-z][A-Za-z '\-.]{0,62}$")  # ascii names only, nothing else
CODE = re.compile(r"^[A-Z0-9]{1,10}$")


def clean_name(value):
    value = value.strip()
    return value if NAME.match(value) else None


def number(value, low, high):
    try:
        n = float(value)
    except ValueError:
        return None
    return n if low <= n <= high else None


def main():
    source, out = Path(sys.argv[1]), Path(sys.argv[2])
    dropped = 0

    # country code → name
    countries = {}
    for line in (source / "countryInfo.txt").read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) < 5 or not CODE.match(fields[0]):
            continue
        name = clean_name(fields[4])
        if name:
            countries[fields[0]] = name

    # "IN.33" → "Goa"
    regions = {}
    for line in (source / "admin1CodesASCII.txt").read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) < 3:
            continue
        country, _, code = fields[0].partition(".")
        name = clean_name(fields[2])  # the ascii column
        if CODE.match(country) and CODE.match(code) and name:
            regions[fields[0]] = name

    # geonames columns: 2 asciiname, 4 latitude, 5 longitude, 8 country, 10 admin1, 14 population
    cities = []
    for line in (source / "cities15000.txt").read_text(encoding="utf-8").splitlines():
        fields = line.split("\t")
        if len(fields) != 19:
            dropped += 1
            continue
        name = clean_name(fields[2])
        lat = number(fields[4], -90, 90)
        lon = number(fields[5], -180, 180)
        country = fields[8] if CODE.match(fields[8]) else None
        population = number(fields[14], 0, 50_000_000)
        if not (name and lat is not None and lon is not None and country and population is not None):
            dropped += 1
            continue
        region = f"{country}.{fields[10]}" if CODE.match(fields[10] or "-") else None
        cities.append([name, round(lat, 4), round(lon, 4), country, region if region in regions else None, int(population)])

    out.write_text(json.dumps({
        "source": "geonames.org cities15000, CC-BY 4.0",
        "countries": countries,
        "regions": regions,
        "cities": cities,  # [name, lat, lon, country, region, population]
    }, separators=(",", ":"), ensure_ascii=True))
    print(f"✓ {len(cities)} cities, {len(regions)} regions, {len(countries)} countries → {out} "
          f"({out.stat().st_size / 1e6:.1f} MB, dropped {dropped})")


if __name__ == "__main__":
    main()
