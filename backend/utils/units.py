"""
Unit conversion utilities

Functions for normalizing and converting units of measurement.
"""

from typing import Tuple


def normalize_unit(unit: str) -> str:
    """Normalize various unit representations to standard units"""
    if unit is None:
        return ""
    u = str(unit).strip().lower()
    if not u:
        return ""
    # IMPORTANT: kg/l are PRESERVED here (not collapsed to g/ml). Collapsing the
    # label without scaling qty causes "1kg" to become "1g". Callers that need a
    # base-unit quantity must go through convert_to_base_unit().
    unit_map = {
        "kg": "kg",
        "킬로그램": "kg",
        "kilogram": "kg",
        "kilograms": "kg",
        "g": "g",
        "gram": "g",
        "grams": "g",
        "gramme": "g",
        "grammes": "g",
        "그램": "g",
        "l": "l",
        "liter": "l",
        "litre": "l",
        "liters": "l",
        "litres": "l",
        "리터": "l",
        "ml": "ml",
        "cc": "ml",
        "milliliter": "ml",
        "milliliters": "ml",
        "millilitre": "ml",
        "millilitres": "ml",
        "밀리리터": "ml",
        "t": "큰술",
        "tbsp": "큰술",
        "tsp": "작은술",
        "큰술": "큰술",
        "작은술": "작은술",
    }
    return unit_map.get(u, u)


def convert_to_base_unit(qty: float, unit: str) -> Tuple[float, str]:
    """Convert quantity to base units (g or ml)"""
    unit_conversions = {
        'kg': (1000, 'g'),
        '킬로그램': (1000, 'g'),
        'l': (1000, 'ml'),
        '리터': (1000, 'ml'),
        # Lone "t"/"T" in user/recipe payloads = tablespoon, not metric ton.
        't': (15, 'ml'),
        'tbsp': (15, 'ml'),
        '큰술': (15, 'ml'),
        'tsp': (5, 'ml'),
        '작은술': (5, 'ml'),
    }
    
    if unit.lower() in unit_conversions:
        multiplier, new_unit = unit_conversions[unit.lower()]
        return (qty * multiplier, new_unit)
    
    return (qty, normalize_unit(unit))


def normalize_units(text: str) -> str:
    """
    Normalize unit text in recipe transcripts.
    Converts fractions and standardizes unit names.
    """
    return (text
            .replace("½", "0.5").replace("¼", "0.25").replace("¾", "0.75")
            .replace("tablespoons", "tbsp").replace("tablespoon", "tbsp")
            .replace("teaspoons", "tsp").replace("teaspoon", "tsp"))

