"""Component catalogs: shadcn/ui, React Bits and the community registries the shadcn CLI knows."""

from __future__ import annotations

import difflib
import re

# shadcn/ui components ('npx shadcn add <name>'). Blocks such as login-03 or dashboard-01 also work with 'rgen ui'.
SHADCN = [
    "accordion", "alert", "alert-dialog", "aspect-ratio", "avatar", "badge", "breadcrumb", "button",
    "button-group", "calendar", "card", "carousel", "chart", "checkbox", "collapsible", "command",
    "context-menu", "dialog", "drawer", "dropdown-menu", "empty", "field", "form", "hover-card", "input",
    "input-group", "input-otp", "item", "kbd", "label", "menubar", "navigation-menu", "pagination",
    "popover", "progress", "radio-group", "resizable", "scroll-area", "select", "separator", "sheet",
    "sidebar", "skeleton", "slider", "sonner", "spinner", "switch", "table", "tabs", "textarea", "toggle",
    "toggle-group", "tooltip",
]

# What 'rgen init' installs.
ESSENTIALS = [
    "button", "input", "label", "textarea", "checkbox", "select", "card", "table", "badge", "skeleton",
    "dialog", "alert-dialog", "dropdown-menu", "separator", "sonner", "avatar", "tooltip",
]

# shadcn blocks: full sections ('rgen ui login-03').
SHADCN_BLOCKS = {
    "dashboard-01": "dashboard with sidebar, charts and a data table",
    "sidebar-01..16": "sidebar layouts (sidebar-07 = collapsible to icons)",
    "login-01..05": "login pages",
    "signup-01..05": "sign-up pages",
    "otp-01..05": "one-time-code pages",
    "calendar-01..32": "calendar variants",
}

# React Bits (reactbits.dev), installed as @react-bits/<Name>-TS-TW.
REACT_BITS = {
    "text": [
        "ASCIIText", "BlurText", "CircularText", "CountUp", "CurvedLoop", "DecryptedText", "DepthText",
        "EchoText", "FallingText", "FoldText", "FuzzyText", "GlitchText", "GradientText", "MaskedHeading",
        "ParticleText", "RotatingText", "ScrambledText", "ScrollFloat", "ScrollReveal", "ScrollVelocity",
        "ShinyText", "Shuffle", "SplitFlapText", "SplitText", "StrokeText", "TechText", "TextCursor",
        "TextLoop", "TextPressure", "TextType", "TrueFocus", "VariableProximity", "WarpText",
    ],
    "animations": [
        "AnimatedContent", "BlobCursor", "ClickSpark", "Crosshair", "CrystalizedBall", "Cubes", "CursorGrid",
        "DitherVeil", "ElasticMesh", "ElectricBorder", "ElectricLogo", "FadeContent", "GhostCursor",
        "GlareHover", "GlowCursor", "GradualBlur", "HalftoneReveal", "ImageTrail", "LaserFlow", "LogoLoop",
        "Magnet", "MetaBalls", "MetallicPaint", "Noise", "OrbitImages", "PixelSwap", "PixelTrail",
        "PixelTransition", "Ribbons", "RippleDistortion", "ScrollExpand", "ShapeBlur", "SplashCursor",
        "StarBorder", "StickerPeel", "Strands", "SwarmCursor", "TargetCursor",
    ],
    "components": [
        "AccordionGallery", "AnimatedList", "BorderGlow", "BounceCards", "BubbleMenu", "CardNav", "CardSwap",
        "Carousel", "ChromaGrid", "CircularCarousel", "CircularGallery", "Counter", "CurvedInput", "DecayCard",
        "DepthCarousel", "Dock", "DomeGallery", "DriftWall", "ElasticSlider", "FlexCarousel", "FlowingMenu",
        "FluidGlass", "FlyingPosters", "Folder", "GlassIcons", "GlassSurface", "GooeyNav", "HoloCard",
        "InfiniteMenu", "InfiniteSpiral", "Lanyard", "LineSidebar", "MagicBento", "Masonry", "ModelViewer",
        "MorphSlider", "OptionWheel", "PillNav", "PixelCard", "ProfileCard", "ReflectiveCard", "ScrollStack",
        "SpecularButton", "SpotlightCard", "Stack", "StaggeredMenu", "Stepper", "TiltedCard",
    ],
    "backgrounds": [
        "AcidSquares", "AeroShards", "Antigravity", "Aurora", "Balatro", "Ballpit", "Beams", "ColorBends",
        "CRTWarp", "DarkVeil", "Dither", "DotField", "DotGrid", "FaultyTerminal", "Ferrofluid", "FloatingLines",
        "FluxLines", "Galaxy", "GhostFibers", "GradientASCII", "GradientBlinds", "GradientWaves", "Grainient",
        "GridDistortion", "GridMotion", "GridScan", "Hyperspeed", "Iridescence", "LetterGlitch", "Lightfall",
        "Lightning", "LightPillar", "LightRays", "LightTunnel", "LineWaves", "LiquidChrome", "LiquidEther",
        "MagicRings", "MagnetLines", "MicroSlats", "MoltenMetal", "Orb", "Particles", "PatternWaves",
        "PixelBlast", "PixelSnow", "Plasma", "PlasmaWave", "Prism", "PrismaticBurst", "Radar", "RippleGrid",
        "Scanner", "ShapeGrid", "ShapeWaves", "SideRays", "Silk", "SlicedWaves", "SoftAurora", "Threads",
        "Topography", "Waves", "WebThreads",
    ],
}

# Registries built into the shadcn CLI index (no components.json entry needed): 'rgen add @ns/name'.
REGISTRIES = {
    "@react-bits": "https://reactbits.dev - animated text, backgrounds, effects (use 'rgen bits')",
    "@magicui": "https://magicui.design - animated landing-page components (marquee, globe, bento-grid, ...)",
    "@aceternity": "https://ui.aceternity.com - flashy hero sections, cards, backgrounds",
    "@animate-ui": "https://animate-ui.com - animated versions of shadcn primitives",
    "@kibo-ui": "https://www.kibo-ui.com - gantt, kanban, editor, dropzone, color picker, ...",
    "@cult-ui": "https://www.cult-ui.com - headless, composable extras",
    "@motion-primitives": "https://motion-primitives.com - motion building blocks",
    "@shadcnblocks": "https://shadcnblocks.com - ready page sections (heroes, pricing, footers)",
    "@8bitcn": "https://www.8bitcn.com - retro 8-bit styled components",
}


def _key(name: str) -> str:
    return re.sub(r"[^a-z0-9]", "", name.lower())


_BITS_INDEX = {_key(n): n for names in REACT_BITS.values() for n in names}


def resolve_bits(name: str) -> tuple[str, bool]:
    """'split-text' / 'splittext' / 'SplitText' -> ('SplitText', known)."""
    found = _BITS_INDEX.get(_key(name))
    if found:
        return found, True
    pascal = "".join(p[:1].upper() + p[1:] for p in re.split(r"[-_\s]+", name) if p)
    return pascal, False


def suggest_bits(name: str) -> list[str]:
    return [_BITS_INDEX[k] for k in difflib.get_close_matches(_key(name), list(_BITS_INDEX), n=3, cutoff=0.6)]
