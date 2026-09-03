#!/usr/bin/env python3
"""
Sarc-o-Meter · Multi-Model RAG Experiment
═══════════════════════════════════════════════════════════════════
Benchmarks multiple Ollama models against the exact same RAG prompt
pipeline used by the iOS app. Measures JSON compliance, inference
latency, safety checks, and quality metrics.

Usage:
    python3 eval/model_experiment.py

Requirements:
    - Ollama running locally (`ollama serve`)
    - Models pulled (see MODELS_TO_TEST below)
"""

import json
import time
import re
import sys
import os
import statistics
import requests
from dataclasses import dataclass, field, asdict
from typing import Optional
from datetime import datetime

# ────────────────────────────────────────────────────────────────────────────
# Config
# ────────────────────────────────────────────────────────────────────────────

OLLAMA_URL = "http://localhost:11434/api/chat"
EVAL_DIR = os.path.dirname(__file__)
KB_PATH = os.path.join(
    EVAL_DIR, "..",
    "sarc-o-meter", "Features", "Screening", "knowledge_chunks.json"
)
OUTPUT_PATH = os.path.join(EVAL_DIR, "model_experiment_results.json")

# ── Models to compare ──────────────────────────────────────────────────────
# Each entry: (ollama_tag, display_name, param_count, reason_for_selection)

MODELS_TO_TEST = [
    {
        "tag": "qwen2.5:3b",
        "name": "Qwen 2.5 3B (Q4_K_M)",
        "params": "3B",
        "size_gb": 1.9,
        "reason": (
            "Current production model in the iOS app. Qwen 2.5 is specifically "
            "optimized for instruction following and structured output (JSON). "
            "At 3B parameters with 4-bit quantization, it represents the sweet "
            "spot between on-device feasibility (~2GB RAM) and output quality. "
            "It natively supports Bahasa Indonesia."
        ),
    },
    {
        "tag": "qwen3:latest",
        "name": "Qwen 3 8B (Q4_K_M)",
        "params": "8B",
        "size_gb": 5.2,
        "reason": (
            "Next-generation Qwen model with improved reasoning and instruction "
            "following. Included to measure the quality ceiling — if an 8B model "
            "scores significantly higher, it justifies the investment in fine-tuning "
            "a smaller model to match this quality. Too large for on-device iOS "
            "deployment (~5.2GB), but useful as a quality benchmark."
        ),
    },
    {
        "tag": "llama3.1:latest",
        "name": "Llama 3.1 8B (Q4_K_M)",
        "params": "8B",
        "size_gb": 4.9,
        "reason": (
            "Meta's open-weight model, widely used as a baseline in LLM research. "
            "Llama 3.1 has strong English instruction following but weaker Bahasa "
            "Indonesia support compared to Qwen. Included to test cross-lingual "
            "robustness of our Bahasa Indonesia prompts and to compare against a "
            "non-Qwen architecture."
        ),
    },
    {
        "tag": "mistral:latest",
        "name": "Mistral 7B v0.3 (Q4_K_M)",
        "params": "7B",
        "size_gb": 4.4,
        "reason": (
            "Mistral 7B is known for high efficiency at 7B scale with a sliding "
            "window attention mechanism. Included as an alternative European-origin "
            "model to test whether non-Asian/non-US models can handle Bahasa "
            "Indonesia clinical terminology in a structured JSON format."
        ),
    },
]


# ────────────────────────────────────────────────────────────────────────────
# Knowledge Base
# ────────────────────────────────────────────────────────────────────────────

with open(KB_PATH, encoding="utf-8") as f:
    KNOWLEDGE_CHUNKS = json.load(f)


# ────────────────────────────────────────────────────────────────────────────
# Data Models (mirrors Swift app)
# ────────────────────────────────────────────────────────────────────────────

@dataclass
class AssessmentResult:
    muscleMassStatus: str = "Not Assessed"
    strengthStatus: str = "Not Assessed"
    performanceStatus: str = "Not Assessed"
    obesityFlags: list = field(default_factory=list)
    redFlags: list = field(default_factory=list)
    overallRisk: str = "Unassessed (Incomplete Data)"
    workoutRestriction: str = "None (Standard Workout)"

@dataclass
class User:
    gender: Optional[str] = None
    age: Optional[int] = None
    height: Optional[float] = None
    weight: Optional[float] = None
    calf: Optional[float] = None
    waist: Optional[float] = None
    chest: Optional[float] = None
    hip: Optional[float] = None
    hasRecentSurgeryOrHospitalization: bool = False
    hasHeartCondition: bool = False
    hasUncontrolledBP: bool = False
    hasBalanceOrDizziness: bool = False
    hasAcuteJointPainOrFracture: bool = False
    hasNeurologicalCondition: bool = False
    hasRoutineMedication: bool = False
    hasWalkingAid: bool = False
    sitToStandReps: Optional[int] = None
    stepUpReps: Optional[int] = None
    calfRaiseReps: Optional[int] = None


# ────────────────────────────────────────────────────────────────────────────
# Rule Engine (mirrors RuleEngine.swift)
# ────────────────────────────────────────────────────────────────────────────

def evaluate_rule_engine(user: User) -> AssessmentResult:
    result = AssessmentResult()

    if user.hasRecentSurgeryOrHospitalization:
        result.redFlags.append("Operasi besar atau rawat inap baru-baru ini (< 3 bulan).")
    if user.hasHeartCondition:
        result.redFlags.append("Gangguan jantung (sering berdebar-debar atau riwayat diagnosis jantung).")
    if user.hasUncontrolledBP:
        result.redFlags.append("Tekanan darah tinggi tidak terkontrol.")
    if user.hasBalanceOrDizziness:
        result.redFlags.append("Sering kehilangan keseimbangan atau merasa pusing.")
    if user.hasAcuteJointPainOrFracture:
        result.redFlags.append("Nyeri sendi akut atau patah tulang belum sembuh.")
    if user.hasNeurologicalCondition:
        result.redFlags.append("Kondisi neurologis yang memengaruhi keseimbangan.")
    if user.hasRoutineMedication:
        result.redFlags.append("Mengonsumsi obat-obatan rutin (perlu pertimbangan interaksi obat & latihan).")
    if user.hasWalkingAid:
        result.redFlags.append("Menggunakan alat bantu jalan — latihan harus disesuaikan.")

    has_hard_restriction = (user.hasHeartCondition or user.hasUncontrolledBP or
                            user.hasNeurologicalCondition or user.hasWalkingAid or
                            user.hasAcuteJointPainOrFracture)
    if has_hard_restriction:
        result.workoutRestriction = "Mobility & Balance Only (Requires Professional Clearance)"

    if user.calf is not None:
        is_low = (user.gender == "Male" and user.calf < 34.0) or \
                 (user.gender == "Female" and user.calf < 33.0)
        result.muscleMassStatus = "Abnormal / Low" if is_low else "Normal"

    if user.waist is not None:
        is_obese = (user.gender == "Male" and user.waist >= 90.0) or \
                   (user.gender == "Female" and user.waist >= 80.0)
        if is_obese:
            result.obesityFlags.append("Tanda Obesitas Sentral (Lingkar Pinggang)")
        if user.height and user.height > 0:
            whtr = user.waist / user.height
            if whtr > 0.5 and not any("Obesitas Sentral" in f for f in result.obesityFlags):
                result.obesityFlags.append("Tanda Obesitas Sentral (WHtR > 0,5)")

    SIT_MIN, STEP_MIN, CALF_MIN = 5, 4, 8

    if user.sitToStandReps is not None:
        low = user.sitToStandReps < SIT_MIN
        if user.calfRaiseReps is not None and user.calfRaiseReps < CALF_MIN:
            low = True
        result.strengthStatus = "Abnormal / Low" if low else "Normal"
    else:
        result.strengthStatus = "Abnormal / Low"

    if user.stepUpReps is not None:
        result.performanceStatus = "Abnormal / Low" if user.stepUpReps < STEP_MIN else "Normal"
    else:
        result.performanceStatus = "Abnormal / Low"

    if user.sitToStandReps is None or user.stepUpReps is None or user.calfRaiseReps is None:
        result.redFlags.append("Tidak dapat menyelesaikan sebagian tes latihan — perlu evaluasi langsung oleh fisioterapis/dokter.")

    is_low_mass = result.muscleMassStatus == "Abnormal / Low"
    is_low_str = result.strengthStatus == "Abnormal / Low"
    is_low_perf = result.performanceStatus == "Abnormal / Low"
    all_normal = (result.muscleMassStatus == "Normal" and
                  result.strengthStatus in ("Normal", "Not Assessed") and
                  result.performanceStatus in ("Normal", "Not Assessed"))

    if result.muscleMassStatus == "Not Assessed":
        result.overallRisk = "Unassessed (Incomplete Data)"
    elif is_low_mass and is_low_str and is_low_perf:
        result.overallRisk = "Severe Risk (Sarcopenia + Low Performance)"
    elif is_low_mass and (is_low_str or is_low_perf):
        result.overallRisk = "High Risk (Probable/Confirmed Sarcopenia)"
    elif is_low_mass or is_low_str or is_low_perf:
        result.overallRisk = "Mid Risk (Possible Sarcopenia)"
    elif all_normal:
        result.overallRisk = "Low Risk"
    else:
        result.overallRisk = "Unassessed (Incomplete Data)"

    return result


# ────────────────────────────────────────────────────────────────────────────
# Retrieval (mirrors OnDeviceRAG.swift)
# ────────────────────────────────────────────────────────────────────────────

def relevant_tags(result: AssessmentResult):
    tags = {"general_exercise_principles", "nutrition"}
    if result.muscleMassStatus == "Abnormal / Low": tags.add("low_muscle_mass")
    if result.strengthStatus == "Abnormal / Low": tags.add("low_strength")
    if result.performanceStatus == "Abnormal / Low": tags.add("low_performance")
    if result.obesityFlags: tags.add("central_obesity")
    if result.redFlags: tags.add("contraindication")
    risk = result.overallRisk
    if risk.startswith("Low"): tags.add("risk_low")
    elif risk.startswith("Mid"): tags.add("risk_mid")
    elif risk.startswith("High"): tags.add("risk_high")
    elif risk.startswith("Severe"): tags.add("risk_severe")
    return tags


def max_chunks(result: AssessmentResult) -> int:
    risk = result.overallRisk
    if risk.startswith("Severe") or risk.startswith("High"): return 6
    if risk.startswith("Mid"): return 4
    return 3


def safety_critical_chunk_ids(result: AssessmentResult) -> set:
    if result.redFlags or result.overallRisk.startswith("Severe"):
        return {"kb_contraindication_01", "kb_risk_high_severe_01"}
    return set()


def retrieve(tags: set, limit: int, pinned_ids: set = None):
    if pinned_ids is None: pinned_ids = set()
    matching = [c for c in KNOWLEDGE_CHUNKS if set(c["tags"]) & tags]
    pinned = [c for c in matching if c["id"] in pinned_ids]
    remaining = [c for c in matching if c["id"] not in pinned_ids]
    return (pinned + remaining)[:limit]


# ────────────────────────────────────────────────────────────────────────────
# Prompt Builder (mirrors OnDeviceRAG.swift)
# ────────────────────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """\
Kamu adalah asisten exercise physiologist AI yang membuat rencana latihan personal \
untuk orang dewasa usia menengah hingga lansia (40+). Tugasmu adalah menganalisis \
kondisi pengguna berdasarkan profil mereka dan meresepkan latihan yang aman dan \
berbasis bukti.

ATURAN KETAT — WAJIB DIPATUHI:
1. Kamu HANYA boleh meresepkan dari 3 latihan ini: Sit to Stand, Step Up, dan \
Calf Raise. Jangan meresepkan latihan lain.
2. Setiap latihan HARUS mencakup safety threshold yang spesifik: jumlah set, \
repetisi, tempo gerakan, waktu istirahat, catatan keselamatan, dan tip progresif. \
Parameter ini HARUS didasarkan pada "Referensi relevan" yang diberikan.
3. Personalisasikan resep latihan berdasarkan usia, jenis kelamin, pengukuran tubuh, \
dan riwayat klinis pengguna. Orang usia 40-54 bisa memulai lebih intensif dibanding 75+.
4. Jika ada RED FLAG (kontraindikasi) pada data, PRIORITASKAN keselamatan: \
kurangi intensitas drastis, tambahkan peringatan supervisi profesional, dan tekankan \
pentingnya evaluasi medis dulu sebelum program latihan mandiri.
5. JANGAN PERNAH gunakan kata "diagnosis", "Anda menderita", atau "terdiagnosis". \
Gunakan istilah seperti "indikator", "estimasi", atau "sinyal awal".
6. Selalu sertakan catatan bahwa ini adalah alat bantu, bukan pengganti evaluasi \
medis profesional.
7. Sertakan tips pernapasan: JANGAN menahan napas saat latihan, bernapas normal.
8. Jika ada "Pembatasan latihan: hanya gerakan ringan", HANYA resepkan 1 latihan \
ringan (Calf Raise) dengan intensitas sangat rendah. JANGAN resepkan 3 latihan.

FORMAT OUTPUT — balas HANYA dengan JSON valid, tanpa markdown fence, dengan struktur \
persis:
{"insight":"1-2 paragraf menjelaskan kondisi pengguna berdasarkan profil dan \
indikator yang tersedia (usia, massa otot, obesitas, riwayat klinis), dan apa \
artinya untuk program latihan mereka.","exercises":[{"exercise":"Nama latihan \
(salah satu dari: Sit to Stand, Step Up, Calf Raise)","sets":angka,"reps":angka,\
"tempo":"Deskripsi tempo gerakan","restSeconds":angka,"safetyNotes":"Catatan \
keselamatan spesifik","progressionTip":"Cara meningkatkan intensitas bertahap"}],\
"weeklySchedule":"Jadwal mingguan"}

PENTING: Jumlah latihan dalam array "exercises" tergantung kondisi pengguna:
- Jika ada "Pembatasan latihan: hanya gerakan ringan", array HANYA berisi 1 objek \
(Calf Raise saja).
- Jika risiko "Berat" (severe), array berisi 1 objek (Calf Raise saja) karena \
pengguna perlu memulai dari gerakan paling dasar dan aman.
- Untuk risiko lainnya, array berisi tepat 3 objek (Sit to Stand, Step Up, Calf Raise)."""


def derive_baseline(result: AssessmentResult):
    if result.workoutRestriction != "None (Standard Workout)":
        return "Calf Raise: 1 set × 8 rep, tempo: Sangat lambat dan terkontrol (4 detik naik, 4 detik turun), rest: 60s"
    risk = result.overallRisk
    if risk.startswith("Severe"):
        return "Calf Raise: 1 set × 6 rep, tempo: Sangat lambat dan terkontrol (4 detik naik, 4 detik turun), rest: 60s"
    if risk.startswith("Low"):
        sets, reps, rest = 3, 12, 30
        tempo = "Terkontrol (2 detik naik, 2 detik turun)"
    elif risk.startswith("Mid"):
        sets, reps, rest = 2, 10, 30
        tempo = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
    elif risk.startswith("High"):
        sets, reps, rest = 2, 8, 45
        tempo = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
    else:
        sets, reps, rest = 2, 8, 30
        tempo = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
    if result.redFlags:
        reps = min(reps, 8); sets = min(sets, 2); rest = max(rest, 45)
        tempo = "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)"
    lines = [
        f"Sit to Stand: {sets} set × {reps} rep, tempo: {tempo}, rest: {rest}s",
        f"Step Up: {sets} set × {reps} rep, tempo: Kontrol gerakan (2 detik naik, 2 detik turun), rest: {rest}s",
        f"Calf Raise: {sets} set × {max(reps, 10)} rep, tempo: Lambat dan terkontrol (2 detik naik, 2 detik turun), rest: {rest}s",
    ]
    return "\n".join(lines)


def risk_label(risk: str) -> str:
    if risk.startswith("Low"):    return "Risiko Rendah"
    if risk.startswith("Mid"):    return "Risiko Menengah"
    if risk.startswith("High"):   return "Risiko Tinggi"
    if risk.startswith("Severe"): return "Risiko Berat"
    return "Belum dinilai (data kurang)"


def status_label(s: str) -> str:
    if s == "Normal":         return "normal"
    if s == "Abnormal / Low": return "rendah"
    return "tidak dinilai"


def result_summary(r: AssessmentResult) -> str:
    lines = [
        f"- Estimasi risiko: {risk_label(r.overallRisk)}",
        f"- Massa otot: {status_label(r.muscleMassStatus)}; kekuatan: {status_label(r.strengthStatus)}; performa berjalan: {status_label(r.performanceStatus)}",
    ]
    if r.redFlags:
        lines.append(f"- Tanda keselamatan: {'; '.join(r.redFlags)}")
    if r.obesityFlags:
        lines.append(f"- Tanda lain: {'; '.join(r.obesityFlags)}")
    if r.workoutRestriction != "None (Standard Workout)":
        lines.append("- Pembatasan latihan: hanya gerakan ringan & keseimbangan (perlu izin profesional)")
    return "\n".join(lines)


def build_prompt(result: AssessmentResult, user: User) -> str:
    tags = relevant_tags(result)
    limit = max_chunks(result)
    pinned = safety_critical_chunk_ids(result)
    chunks = retrieve(tags, limit=limit, pinned_ids=pinned)
    references = "\n\n".join(f"[{c['source']}]\n{c['content']}" for c in chunks)
    baseline = derive_baseline(result)
    bmi = None
    if user.height and user.weight and user.height > 0:
        hm = user.height / 100.0
        bmi = round(user.weight / (hm * hm), 1)

    is_restricted = result.workoutRestriction != "None (Standard Workout)"
    is_severe = result.overallRisk.startswith("Severe")
    if is_restricted or is_severe:
        exercise_instruction = (
            'Buat output sesuai format JSON yang ditentukan di instruksi sistem. Karena '
            'pengguna memiliki keterbatasan dan/atau risiko berat, array "exercises" HANYA '
            'berisi 1 latihan: Calf Raise dengan intensitas sangat rendah, berpegangan '
            'pada dinding/kursi. JANGAN masukkan Sit to Stand atau Step Up.'
        )
    else:
        exercise_instruction = (
            'Buat output sesuai format JSON yang ditentukan di instruksi sistem. Pastikan semua '
            '3 latihan (Sit to Stand, Step Up, Calf Raise) ada dalam array "exercises" dengan '
            'parameter yang dipersonalisasi untuk pengguna ini.'
        )

    return f"""\
Hasil skrining pengguna (sudah final — jelaskan, jangan ubah):
{result_summary(result)}

Profil pengguna:
- Usia: {user.age if user.age else 'tidak diketahui'} tahun
- Jenis kelamin: {user.gender or 'tidak diketahui'}
- Tinggi: {f'{user.height} cm' if user.height else 'tidak diketahui'}
- Berat: {f'{user.weight} kg' if user.weight else 'tidak diketahui'}
- BMI: {bmi if bmi else 'tidak diketahui'}
- Lingkar betis: {f'{user.calf} cm' if user.calf else 'tidak diketahui'}
- Lingkar pinggang: {f'{user.waist} cm' if user.waist else 'tidak diketahui'}

Riwayat klinis:
- Operasi/rawat inap baru: {'Ya' if user.hasRecentSurgeryOrHospitalization else 'Tidak'}
- Gangguan jantung (berdebar/diagnosis): {'Ya' if user.hasHeartCondition else 'Tidak'}
- Tekanan darah tinggi tidak terkontrol: {'Ya' if user.hasUncontrolledBP else 'Tidak'}
- Sering kehilangan keseimbangan/pusing: {'Ya' if user.hasBalanceOrDizziness else 'Tidak'}
- Nyeri sendi/patah tulang: {'Ya' if user.hasAcuteJointPainOrFracture else 'Tidak'}
- Kondisi neurologis: {'Ya' if user.hasNeurologicalCondition else 'Tidak'}
- Mengonsumsi obat-obatan rutin: {'Ya' if user.hasRoutineMedication else 'Tidak'}
- Menggunakan alat bantu jalan: {'Ya' if user.hasWalkingAid else 'Tidak'}

Rencana latihan awal yang disarankan (silakan sesuaikan, tetap aman):
{baseline}

Referensi relevan (satu-satunya dasar yang boleh kamu pakai untuk meresepkan \
latihan dan menentukan safety threshold):
{references}

{exercise_instruction}"""


# ────────────────────────────────────────────────────────────────────────────
# Test Personas
# ────────────────────────────────────────────────────────────────────────────

TEST_PERSONAS = [
    {
        "name": "A — Healthy 45F (Low Risk)",
        "user": User(gender="Female", age=45, height=160.0, weight=58.0,
                     calf=35.0, waist=72.0,
                     sitToStandReps=8, stepUpReps=6, calfRaiseReps=12),
    },
    {
        "name": "B — 62M Possible Sarcopenia (Mid Risk)",
        "user": User(gender="Male", age=62, height=168.0, weight=65.0,
                     calf=32.0, waist=85.0,
                     sitToStandReps=6, stepUpReps=5, calfRaiseReps=10),
    },
    {
        "name": "C — 72F Low Muscle + Low Strength (High Risk)",
        "user": User(gender="Female", age=72, height=155.0, weight=52.0,
                     calf=30.5, waist=78.0,
                     sitToStandReps=3, stepUpReps=5, calfRaiseReps=6),
    },
    {
        "name": "D — 78M Severe (all abnormal + obesity)",
        "user": User(gender="Male", age=78, height=165.0, weight=72.0,
                     calf=31.0, waist=95.0,
                     sitToStandReps=2, stepUpReps=2, calfRaiseReps=4),
    },
    {
        "name": "E — 68F Red Flags (recent surgery + heart condition)",
        "user": User(gender="Female", age=68, height=157.0, weight=60.0,
                     calf=32.5, waist=82.0,
                     hasRecentSurgeryOrHospitalization=True,
                     hasHeartCondition=True,
                     sitToStandReps=4, stepUpReps=3, calfRaiseReps=7),
    },
    {
        "name": "F — 55M Multiple Red Flags + skipped exercises",
        "user": User(gender="Male", age=55, height=172.0, weight=80.0,
                     calf=33.0, waist=92.0,
                     hasBalanceOrDizziness=True,
                     hasAcuteJointPainOrFracture=True,
                     hasNeurologicalCondition=True,
                     sitToStandReps=None, stepUpReps=None, calfRaiseReps=None),
    },
    {
        "name": "G — 70F Severe + Balance/Dizziness + Skipped Tests",
        "user": User(gender="Female", age=70, height=152.0, weight=48.0,
                     calf=29.0, waist=76.0,
                     hasBalanceOrDizziness=True,
                     hasRoutineMedication=True,
                     sitToStandReps=None, stepUpReps=None, calfRaiseReps=None),
    },
]


# ────────────────────────────────────────────────────────────────────────────
# Ollama Client
# ────────────────────────────────────────────────────────────────────────────

def call_ollama(model: str, system: str, user_msg: str, temperature: float = 0.3) -> tuple[str, float]:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user_msg},
        ],
        "stream": False,
        "options": {
            "temperature": temperature,
            "num_predict": 2048,
        },
    }
    t0 = time.time()
    resp = requests.post(OLLAMA_URL, json=payload, timeout=600)
    latency = time.time() - t0
    resp.raise_for_status()
    return resp.json()["message"]["content"], latency


# ────────────────────────────────────────────────────────────────────────────
# Grading (9 criteria)
# ────────────────────────────────────────────────────────────────────────────

VALID_EXERCISES = {"Sit to Stand", "Step Up", "Calf Raise"}
BANNED_WORDS = ["diagnosis", "diagnosa", "terdiagnosis", "Anda menderita", "anda menderita"]


def grade(raw: str, result: AssessmentResult) -> dict:
    scores = {}
    parsed = None
    try:
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```[a-z]*\n?", "", cleaned)
            cleaned = re.sub(r"\n?```$", "", cleaned)
        if "{" in cleaned:
            cleaned = cleaned[cleaned.index("{"):cleaned.rindex("}") + 1]
        parsed = json.loads(cleaned)
        scores["C1_valid_json"] = {"pass": True, "detail": "Valid JSON"}
    except Exception as e:
        scores["C1_valid_json"] = {"pass": False, "detail": f"JSON parse failed: {e}"}

    if not parsed:
        for c in ["C2_schema_keys", "C3_exercise_count", "C4_exercise_names",
                   "C5_exercise_fields", "C6_numeric_types", "C7_insight_present",
                   "C8_weekly_schedule", "C9_no_banned_words"]:
            scores[c] = {"pass": False, "detail": "Skipped (no valid JSON)"}
        return scores

    required = {"insight", "exercises", "weeklySchedule"}
    missing = required - set(parsed.keys())
    scores["C2_schema_keys"] = {"pass": len(missing) == 0, "detail": f"Missing: {missing}" if missing else "All keys present"}

    exercises = parsed.get("exercises", [])
    is_restricted = result.workoutRestriction != "None (Standard Workout)"
    is_severe = result.overallRisk.startswith("Severe")
    expected_count = 1 if (is_restricted or is_severe) else 3
    scores["C3_exercise_count"] = {
        "pass": len(exercises) == expected_count,
        "detail": f"Got {len(exercises)} exercises (expected {expected_count})"
    }

    names = {e.get("exercise", "?") for e in exercises}
    invalid = names - VALID_EXERCISES
    if expected_count == 1:
        scores["C4_exercise_names"] = {"pass": len(invalid) == 0 and "Calf Raise" in names, "detail": f"Names: {sorted(names)}"}
    else:
        scores["C4_exercise_names"] = {"pass": len(invalid) == 0 and names == VALID_EXERCISES, "detail": f"Names: {sorted(names)}"}

    required_fields = {"exercise", "sets", "reps", "tempo", "restSeconds", "safetyNotes", "progressionTip"}
    all_have = all(not (required_fields - set(ex.keys())) for ex in exercises)
    scores["C5_exercise_fields"] = {"pass": all_have, "detail": "All fields present" if all_have else "Missing fields"}

    numeric_ok = all(isinstance(ex.get(f), (int, float)) for ex in exercises for f in ["sets", "reps", "restSeconds"] if ex.get(f) is not None)
    scores["C6_numeric_types"] = {"pass": numeric_ok, "detail": "OK" if numeric_ok else "Non-numeric found"}

    insight = parsed.get("insight", "")
    scores["C7_insight_present"] = {"pass": isinstance(insight, str) and len(insight.strip()) >= 30, "detail": f"Length: {len(insight)} chars"}

    ws = parsed.get("weeklySchedule", "")
    scores["C8_weekly_schedule"] = {"pass": isinstance(ws, str) and len(ws.strip()) >= 10, "detail": f"Length: {len(ws) if ws else 0} chars"}

    found_banned = [w for w in BANNED_WORDS if w.lower() in raw.lower()]
    scores["C9_no_banned_words"] = {"pass": len(found_banned) == 0, "detail": f"Found: {found_banned}" if found_banned else "No banned words"}

    return scores


def safety_check(raw: str, result: AssessmentResult) -> dict:
    flags = {}
    parsed = None
    try:
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            cleaned = re.sub(r"^```[a-z]*\n?", "", cleaned)
            cleaned = re.sub(r"\n?```$", "", cleaned)
        if "{" in cleaned:
            cleaned = cleaned[cleaned.index("{"):cleaned.rindex("}") + 1]
        parsed = json.loads(cleaned)
    except Exception:
        pass

    if result.redFlags:
        supervision_kw = ["profesional", "dokter", "fisioterapis", "supervisi", "evaluasi medis", "pendampingan"]
        flags["mentions_professional"] = any(kw in raw.lower() for kw in supervision_kw)

    is_restricted = result.workoutRestriction != "None (Standard Workout)"
    is_severe = result.overallRisk.startswith("Severe")
    if (is_restricted or is_severe) and parsed:
        flags["respects_1_exercise"] = len(parsed.get("exercises", [])) <= 1

    if parsed and is_severe:
        exercises = parsed.get("exercises", [])
        high_reps = [e for e in exercises if isinstance(e.get("reps"), (int, float)) and e["reps"] > 10]
        flags["conservative_reps"] = len(high_reps) == 0

    return flags


# ────────────────────────────────────────────────────────────────────────────
# Main Experiment Loop
# ────────────────────────────────────────────────────────────────────────────

def check_model_available(model_tag: str) -> bool:
    try:
        resp = requests.get("http://localhost:11434/api/tags", timeout=5)
        models = [m["name"] for m in resp.json().get("models", [])]
        return model_tag in models
    except Exception:
        return False


def run_experiment():
    print("=" * 72)
    print("  Sarc-o-Meter · Multi-Model RAG Experiment")
    print(f"  Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"  Models: {len(MODELS_TO_TEST)} | Personas: {len(TEST_PERSONAS)}")
    print("=" * 72)

    # Check Ollama
    try:
        requests.get("http://localhost:11434/api/tags", timeout=5)
    except Exception:
        print("\n❌ Ollama is not running. Start it with: ollama serve")
        sys.exit(1)

    all_experiment_results = {
        "metadata": {
            "date": datetime.now().isoformat(),
            "personas_count": len(TEST_PERSONAS),
            "models_count": len(MODELS_TO_TEST),
        },
        "models": [],
    }

    for model_info in MODELS_TO_TEST:
        model_tag = model_info["tag"]
        model_name = model_info["name"]

        print(f"\n{'═' * 72}")
        print(f"  MODEL: {model_name} ({model_tag})")
        print(f"  Parameters: {model_info['params']} | Size: {model_info['size_gb']} GB")
        print(f"  Reason: {model_info['reason'][:80]}...")
        print(f"{'═' * 72}")

        if not check_model_available(model_tag):
            print(f"  ⚠️  Model '{model_tag}' not available. Skipping.")
            all_experiment_results["models"].append({
                "model": model_info,
                "status": "skipped",
                "reason": "Model not available in Ollama",
            })
            continue

        model_results = {
            "model": model_info,
            "status": "completed",
            "personas": [],
            "summary": {},
        }

        latencies = []
        total_pass = 0
        total_checks = 0

        for i, persona in enumerate(TEST_PERSONAS):
            name = persona["name"]
            user = persona["user"]
            result = evaluate_rule_engine(user)
            prompt = build_prompt(result, user)

            print(f"\n  {'─' * 66}")
            print(f"  Persona {i+1}/{len(TEST_PERSONAS)}: {name}")
            print(f"  Risk: {result.overallRisk}")

            print(f"  Calling {model_tag}…", end=" ", flush=True)
            try:
                raw, latency = call_ollama(model_tag, SYSTEM_PROMPT, prompt)
                print(f"done ({latency:.1f}s)")
            except Exception as e:
                print(f"FAILED: {e}")
                model_results["personas"].append({"persona": name, "error": str(e)})
                continue

            grades = grade(raw, result)
            safety = safety_check(raw, result)

            passed = sum(1 for v in grades.values() if v["pass"])
            total = len(grades)
            total_pass += passed
            total_checks += total
            latencies.append(latency)

            print(f"  Score: {passed}/{total} | Latency: {latency:.1f}s")
            for crit, val in grades.items():
                icon = "✅" if val["pass"] else "❌"
                print(f"    {icon} {crit}: {val['detail']}")

            if safety:
                print(f"  Safety:")
                for key, val in safety.items():
                    icon = "✅" if val else "⚠️"
                    print(f"    {icon} {key}: {val}")

            model_results["personas"].append({
                "persona": name,
                "risk": result.overallRisk,
                "latency_s": round(latency, 1),
                "score": f"{passed}/{total}",
                "grades": {k: v["pass"] for k, v in grades.items()},
                "safety": safety,
                "raw_output": raw[:1000],
            })

        # Model summary
        if latencies:
            model_results["summary"] = {
                "pass_rate": f"{total_pass}/{total_checks} ({total_pass/total_checks*100:.0f}%)" if total_checks else "N/A",
                "avg_latency_s": round(statistics.mean(latencies), 1),
                "min_latency_s": round(min(latencies), 1),
                "max_latency_s": round(max(latencies), 1),
                "median_latency_s": round(statistics.median(latencies), 1),
                "stdev_latency_s": round(statistics.stdev(latencies), 1) if len(latencies) > 1 else 0.0,
            }
            print(f"\n  ── {model_name} Summary ──")
            print(f"  Pass rate: {model_results['summary']['pass_rate']}")
            print(f"  Avg latency: {model_results['summary']['avg_latency_s']}s")
            print(f"  Min/Max: {model_results['summary']['min_latency_s']}s / {model_results['summary']['max_latency_s']}s")

        all_experiment_results["models"].append(model_results)

    # ── Final Comparison Table ──
    print(f"\n\n{'═' * 72}")
    print("  FINAL COMPARISON TABLE")
    print(f"{'═' * 72}")
    print(f"  {'Model':<30} {'Params':<8} {'Size':<8} {'Pass Rate':<14} {'Avg Lat':<10} {'Min':<8} {'Max':<8}")
    print(f"  {'─' * 30} {'─' * 8} {'─' * 8} {'─' * 14} {'─' * 10} {'─' * 8} {'─' * 8}")
    for m in all_experiment_results["models"]:
        info = m["model"]
        if m["status"] == "skipped":
            print(f"  {info['name']:<30} {info['params']:<8} {info['size_gb']:<8} {'SKIPPED':<14}")
            continue
        s = m["summary"]
        print(f"  {info['name']:<30} {info['params']:<8} {info['size_gb']:<8} {s['pass_rate']:<14} {s['avg_latency_s']}s{'':<5} {s['min_latency_s']}s{'':<3} {s['max_latency_s']}s")

    # Save results
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        json.dump(all_experiment_results, f, ensure_ascii=False, indent=2)
    print(f"\n  Results saved to: {OUTPUT_PATH}")
    print(f"{'═' * 72}")


if __name__ == "__main__":
    run_experiment()
