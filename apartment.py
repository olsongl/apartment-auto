import re
import time
import openpyxl
from datetime import datetime
from playwright.sync_api import sync_playwright
from playwright_stealth import Stealth
from bs4 import BeautifulSoup

# Alphabetical by building name
PROPERTIES = [
    ("Axis at Shady Grove Apartments",
     "https://www.equityapartments.com/maryland/rockville/axis-at-shady-grove-apartments"),
    #("Gaithersburg Station Apartments",
     #"https://www.equityapartments.com/maryland/gaithersburg/gaithersburg-station-apartments"),
    ("The Reserve at Eisenhower Apartments",
     "https://www.equityapartments.com/alexandria/van-dorn-metro/the-reserve-at-eisenhower-apartments"),
    #("Westchester Rockville Station Apartments",
     #"https://www.equityapartments.com/maryland/rockville/westchester-rockville-station-apartments"),
]

RE_UNIT_FEES = re.compile(r'/UnitFees/\d+/([^/]+/[A-Za-z0-9]+)')
RE_UNIT_NUMBER = re.compile(r'unit_prefix=([A-Za-z0-9]+)&amp;unit_number=([A-Za-z0-9]+)')


def parse_units(html, building_name, date_run, time_run):
    soup = BeautifulSoup(html, 'html.parser')
    section = soup.find(id='unit-availability-tile') or soup

    rows = []
    seen_ids = set()

    # Each unit is an <li> with class "unit"
    cards = section.find_all('li', class_='unit')
    print(f"  Found {len(cards)} unit cards in HTML")

    for card in cards:
        # Extract unit ID from /UnitFees/ link or apply link
        # Use prefix/number as unique key since different buildings can share unit numbers
        unique_key = ""
        unit_id = ""
        link = card.find('a', href=RE_UNIT_FEES)
        if link:
            m = RE_UNIT_FEES.search(link['href'])
            if m:
                unique_key = m.group(1)          # e.g. "001/407"
                unit_id = unique_key.split('/')[-1]  # e.g. "407"
        if not unique_key:
            link = card.find('a', href=RE_UNIT_NUMBER)
            if link:
                m = RE_UNIT_NUMBER.search(link['href'])
                if m:
                    unique_key = f"{m.group(1)}/{m.group(2)}"
                    unit_id = m.group(2)
        if not unique_key:
            print(f"  Warning: could not extract unit ID from card")
            continue
        if unique_key in seen_ids:
            continue
        seen_ids.add(unique_key)

        specs = card.find('div', class_='specs') or card

        # Price: find visible pricing span and slashed-out price
        price = ""
        slashed_price = ""
        for span in specs.find_all('span', class_='strikethrough-pricing'):
            if 'ng-hide' not in (span.get('class') or []):
                text = span.get_text(strip=True)
                if text:
                    slashed_price = text
                    break
        for span in specs.find_all('span', class_='pricing'):
            if 'ng-hide' not in (span.get('class') or []):
                text = span.get_text(strip=True)
                if text:
                    price = text
                    break

        # Beds and baths: find the "X Bed / Y Bath" paragraph
        beds = baths = ""
        for p in specs.find_all('p'):
            text = p.get_text(' ', strip=True)
            bm  = re.search(r'(\d+)\s*Bed|Studio', text, re.I)
            btm = re.search(r'(\d+(?:\.\d)?)\s*Bath', text, re.I)
            if bm or btm:
                if bm:
                    beds = bm.group(1) if bm.group(1) else "Studio"
                if btm:
                    baths = btm.group(1)
                break

        # Size: find span containing "sq. ft."
        size = ""
        for span in specs.find_all('span'):
            sm = re.search(r'([\d,]{3,5})\s*sq\.\s*ft\.', span.get_text(strip=True))
            if sm:
                size = sm.group(1).replace(',', '')
                break

        # Availability date: paragraph starting with "Available"
        avail_date = ""
        for p in specs.find_all('p'):
            text = p.get_text(strip=True)
            if re.match(r'Available', text, re.I):
                avail_date = text
                break

        rows.append([building_name, unit_id, beds, baths, price, slashed_price, avail_date, size, date_run, time_run])

    return rows


def main():
    now      = datetime.now()
    date_run = now.strftime("%m/%d/%Y")
    time_run = now.strftime("%H:%M:%S")

    all_rows = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=False, channel="chrome")
        context = browser.new_context(
            user_agent=(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                "AppleWebKit/537.36 (KHTML, like Gecko) "
                "Chrome/122.0.0.0 Safari/537.36"
            ),
            locale="en-US",
            viewport={"width": 1280, "height": 800},
        )

        for i, (building_name, url) in enumerate(PROPERTIES):
            if i > 0:
                print("  Waiting 5 seconds before next page...")
                time.sleep(5)

            print(f"Opening: {building_name}")
            page = context.new_page()
            Stealth().apply_stealth_sync(page)
            page.goto(url, wait_until="domcontentloaded", timeout=30000)

            # Wait for the unit availability section to appear
            try:
                page.wait_for_selector("#unit-availability-tile", timeout=15000)
            except Exception:
                print("  Warning: #unit-availability-tile not found, using full page HTML")

            html = page.content()
            rows = parse_units(html, building_name, date_run, time_run)
            print(f"  → {len(rows)} units found")
            all_rows.extend(rows)
            page.close()

        browser.close()

    wb = openpyxl.Workbook()
    ws = wb.active
    ws.title = "Units"
    ws.append(["Building", "Unit ID", "Bedrooms", "Bathrooms",
                "Price", "Slashed Price", "Available Date", "Size (sq ft)", "Date Run", "Time Run"])

    all_rows.sort(key=lambda r: r[0])
    for row in all_rows:
        ws.append(row)

    from datetime import date
    output = f"apartments_{date.today()}.xlsx"
    wb.save(output)
    print(f"\nDone. {len(all_rows)} total units written to {output}")


if __name__ == "__main__":
    main()
