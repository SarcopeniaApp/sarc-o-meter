#!/usr/bin/env python3
"""
Sarc-o-Meter  ·  Qwen2.5-3B-Instruct-4bit Evaluation Harness
═════════════════════════════════════════════════════════════════
Replicates the EXACT same prompt pipeline that OnDeviceRAG.swift uses,
sends it to the local Ollama Qwen2.5:3b, and grades every response on
the criteria that matter for the app.

Usage:
    python3 eval/evaluate_llm.py

Requirements:
    - Ollama running locally (`ollama serve`)
    - qwen2.5:3b model pulled (`ollama pull qwen2.5:3b`)
"""

import json
import time
import re
import sys
import os
import requests
from dataclasses import dataclass, field, asdict
from typing import Optional

# ────────────────────────────────────────────────────────────────────────────
# 1.  KNOWLEDGE BASE  (mirrors knowledge_chunks.json bundled in the app)
# ────────────────────────────────────────────────────────────────────────────

KB_PATH = os.path.join(
    os.path.dirname(__file__), "..",
    "sarc-o-meter", "Features", "Screening", "knowledge_chunks.json"
)

with open(KB_PATH, encoding="utf-8") as f:
    KNOWLEDGE_CHUNKS = json.load(f)


# ────────────────────────────────────────────────────────────────────────────
# 2.  DATA MODELS  (mirrors AssessmentResult, User, Workout in Swift)
# ────────────────────────────────────────────────────────────────────────────

@dataclass
class ExerciseAbility:
    sitToStandReps: Optional[int]
    stepUpReps: Optional[int]
    calfRaiseReps: Optional[int]

    @property
    def completedAll(self) -> bool:
        return self.sitToStandReps is not None and self.stepUpReps is not None and self.calfRaiseReps is not None

    def grade(self, kind: str) -> str:
        reps = None
        min_adequate = 0
        if kind == "sitToStand":
            reps = self.sitToStandReps
            min_adequate = 5
        elif kind == "stepUp":
            reps = self.stepUpReps
            min_adequate = 4
        elif kind == "calfRaise":
            reps = self.calfRaiseReps
            min_adequate = 8
        if reps is None:
            return "Unable"
        return "Adequate" if reps >= min_adequate else "Limited"

@dataclass
class AssessmentResult:
    muscleMassStatus: str = "Not Assessed"        # Normal | Limited | Abnormal / Low | Not Assessed
    strengthStatus: str = "Not Assessed"
    performanceStatus: str = "Not Assessed"
    obesityFlags: list = field(default_factory=list)
    redFlags: list = field(default_factory=list)
    overallRisk: str = "Unassessed (Incomplete Data)"  # Low Risk | Mid Risk | High Risk | Severe Risk | Unassessed
    workoutRestriction: str = "None (Standard Workout)" # None | Mobility & Balance Only (Requires Professional Clearance)
    exerciseAbility: Optional[ExerciseAbility] = None


@dataclass
class User:
    gender: Optional[str] = None       # "Male" | "Female"
    age: Optional[int] = None
    height: Optional[float] = None     # cm
    weight: Optional[float] = None     # kg
    calf: Optional[float] = None       # cm
    waist: Optional[float] = None      # cm
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
# 3.  RULE ENGINE  (mirrors RuleEngine.swift exactly)
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

    sitToStandMin, stepUpMin, calfRaiseMin = 5, 4, 8
    
    result.exerciseAbility = ExerciseAbility(
        sitToStandReps=user.sitToStandReps,
        stepUpReps=user.stepUpReps,
        calfRaiseReps=user.calfRaiseReps
    )
    
    if user.sitToStandReps is not None:
        if user.sitToStandReps == 0:
            result.strengthStatus = "Abnormal / Low"
        else:
            sitOk = user.sitToStandReps >= sitToStandMin
            calfOk = True if user.calfRaiseReps is None else user.calfRaiseReps >= calfRaiseMin
            if sitOk and calfOk:
                result.strengthStatus = "Normal"
            else:
                result.strengthStatus = "Limited"
    else:
        result.strengthStatus = "Abnormal / Low"

    result.performanceStatus = "Not Assessed"

    if user.sitToStandReps is None or user.stepUpReps is None or user.calfRaiseReps is None:
        result.redFlags.append("Tidak dapat menyelesaikan sebagian tes latihan — perlu evaluasi langsung oleh fisioterapis/dokter.")

    is_low_mass = result.muscleMassStatus == "Abnormal / Low"
    is_low_str = result.strengthStatus == "Abnormal / Low"
    is_limited_str = result.strengthStatus == "Limited"
    all_normal = (result.muscleMassStatus == "Normal" and
                  result.strengthStatus in ("Normal", "Not Assessed"))

    if result.muscleMassStatus == "Not Assessed":
        result.overallRisk = "Unassessed (Incomplete Data)"
    elif is_low_mass and is_low_str:
        result.overallRisk = "Severe Risk (Sarcopenia + Low Performance)"
    elif is_low_mass and is_limited_str:
        result.overallRisk = "High Risk (Probable/Confirmed Sarcopenia)"
    elif is_low_mass or is_low_str:
        result.overallRisk = "High Risk (Probable/Confirmed Sarcopenia)"
    elif is_limited_str:
        result.overallRisk = "Mid Risk (Possible Sarcopenia)"
    elif all_normal:
        result.overallRisk = "Low Risk"
    else:
        result.overallRisk = "Unassessed (Incomplete Data)"

    return result


# ────────────────────────────────────────────────────────────────────────────
# 4.  DETERMINISTIC EXERCISE PLAN  (mirrors ExercisePlan.swift)
# ────────────────────────────────────────────────────────────────────────────

def derive_baseline(result: AssessmentResult):
    if result.workoutRestriction == "Mobility & Balance Only (Requires Professional Clearance)":
        return "Calf Raise: 1 set × 8 rep, tempo: Sangat lambat dan terkontrol (4 detik naik, 4 detik turun), rest: 60s"
    
    if result.exerciseAbility:
        a = result.exerciseAbility
        workouts = []
        if a.grade("sitToStand") != "Unable": workouts.append("Sit to Stand")
        if a.grade("stepUp") != "Unable": workouts.append("Step Up")
        if a.grade("calfRaise") != "Unable": workouts.append("Calf Raise")
        
        if not workouts:
            return "Calf Raise: 1 set × 6 rep, tempo: Sangat lambat dan terkontrol (4 detik naik, 4 detik turun), rest: 60s"
        
        # Approximate baseline output format for LLM since we don't need full scaling logic implemented in Python
        return ", ".join(workouts) + " (Scaled per ability)"
        
    risk = result.overallRisk
    if risk.startswith("Severe"):
        return "Calf Raise: 1 set × 6 rep, tempo: Sangat lambat dan terkontrol (4 detik naik, 4 detik turun), rest: 60s"

    if risk.startswith("Low"):
        sets, reps, rest = 3, 12, 30
        tempo = "Terkontrol (2 detik naik, 2 detik turun)"
    elif risk.startswith("Mid"):
        sets, reps, rest = 2, 10, 30
        tempo = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"
    else:
        sets, reps, rest = 2, 8, 45
        tempo = "Lambat dan terkontrol (3 detik naik, 3 detik turun)"

    if result.redFlags:
        reps = min(reps, 8)
        sets = min(sets, 2)
        rest = max(rest, 45)
        tempo = "Sangat lambat dan terkontrol (4 detik naik, 4 detik turun)"

    lines = [
        f"Sit to Stand: {sets} set × {reps} rep, tempo: {tempo}, rest: {rest}s",
        f"Step Up: {sets} set × {reps} rep, tempo: Kontrol gerakan (2 detik naik, 2 detik turun), rest: {rest}s",
        f"Calf Raise: {sets} set × {max(reps, 10)} rep, tempo: Lambat dan terkontrol (2 detik naik, 2 detik turun), rest: {rest}s",
    ]
    return "\n".join(lines)


# ────────────────────────────────────────────────────────────────────────────
# 5.  RETRIEVAL  (mirrors OnDeviceRAG.swift tag-based retrieval)
# ────────────────────────────────────────────────────────────────────────────

def relevant_tags(result: AssessmentResult):
    tags = {"general_exercise_principles", "nutrition"}
    if result.muscleMassStatus == "Abnormal / Low":
        tags.add("low_muscle_mass")
    if result.strengthStatus == "Abnormal / Low":
        tags.add("low_strength")
    if result.strengthStatus == "Limited":
        tags.add("low_strength")
        tags.add("limited_ability")
    if result.obesityFlags:
        tags.add("central_obesity")
    if result.redFlags:
        tags.add("contraindication")
    risk = result.overallRisk
    if risk.startswith("Low"):
        tags.add("risk_low")
    elif risk.startswith("Mid"):
        tags.add("risk_mid")
    elif risk.startswith("High"):
        tags.add("risk_high")
    elif risk.startswith("Severe"):
        tags.add("risk_severe")
    return tags


def max_chunks(result: AssessmentResult) -> int:
    risk = result.overallRisk
    if risk.startswith("Severe") or risk.startswith("High"):
        return 8
    if risk.startswith("Mid"):
        return 5
    return 3

def safety_critical_chunk_ids(result: AssessmentResult) -> set:
    if result.redFlags or result.overallRisk.startswith("Severe"):
        return {"kb_contraindication_01", "kb_risk_high_severe_01"}
    return set()

def retrieve(tags: set, limit: int, pinned_ids: set = None):
    if pinned_ids is None:
        pinned_ids = set()
    matching_chunks = [c for c in KNOWLEDGE_CHUNKS if set(c["tags"]) & tags]
    pinned = [c for c in matching_chunks if c["id"] in pinned_ids]
    remaining = [c for c in matching_chunks if c["id"] not in pinned_ids]
    return (pinned + remaining)[:limit]


# ────────────────────────────────────────────────────────────────────────────
# 6.  PROMPT BUILDER  (mirrors OnDeviceRAG.swift exactly)
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
- Jika pengguna telah melakukan tes, array HANYA berisi latihan yang BERHASIL \
mereka lakukan (minimal 1 repetisi). JANGAN masukkan latihan yang ditandai \
"Tidak bisa melakukan (dilewati)".
- Jika pengguna sama sekali tidak bisa melakukan semua latihan, array berisi \
1 objek (Calf Raise saja) karena perlu memulai dari gerakan paling dasar.
- Sertakan parameter keselamatan SPESIFIK per latihan: tinggi step (cm), jenis \
kursi (tinggi, stabilitas), kebutuhan pegangan, dari referensi yang diberikan."""


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
        f"- Massa otot: {status_label(r.muscleMassStatus)}; kekuatan: {status_label(r.strengthStatus)}",
    ]
    if r.redFlags:
        lines.append(f"- Tanda keselamatan: {'; '.join(r.redFlags)}")
    if r.obesityFlags:
        lines.append(f"- Tanda lain: {'; '.join(r.obesityFlags)}")
    if r.workoutRestriction != "None (Standard Workout)":
        lines.append("- Pembatasan latihan: hanya gerakan ringan & keseimbangan (perlu izin profesional)")
    return "\n".join(lines)


def build_prompt(result: AssessmentResult, user: User, max_chunks_limit: int = None) -> str:
    tags = relevant_tags(result)
    effective_limit = max_chunks_limit if max_chunks_limit is not None else max_chunks(result)
    pinned = safety_critical_chunk_ids(result)
    chunks = retrieve(tags, limit=effective_limit, pinned_ids=pinned)

    references = "\n\n".join(f"[{c['source']}]\n{c['content']}" for c in chunks)
    baseline = derive_baseline(result)

    bmi = None
    if user.height and user.weight and user.height > 0:
        hm = user.height / 100.0
        bmi = round(user.weight / (hm * hm), 1)

    is_restricted = result.workoutRestriction != "None (Standard Workout)"
    if is_restricted:
        exercise_instruction = (
            'Buat output sesuai format JSON yang ditentukan di instruksi sistem. Karena '
            'pengguna memiliki pembatasan keras, array "exercises" HANYA berisi 1 latihan: '
            'Calf Raise dengan intensitas sangat rendah, berpegangan '
            'pada dinding/kursi. JANGAN masukkan Sit to Stand atau Step Up.'
        )
    elif result.exerciseAbility:
        a = result.exerciseAbility
        unableAll = a.grade("sitToStand") == "Unable" and a.grade("stepUp") == "Unable" and a.grade("calfRaise") == "Unable"
        if unableAll:
            exercise_instruction = (
                'Buat output sesuai format JSON yang ditentukan di instruksi sistem. Karena '
                'pengguna sama sekali tidak bisa melakukan tes kekuatan, array "exercises" '
                'HANYA berisi 1 latihan dasar: Calf Raise dengan intensitas sangat rendah. '
                'JANGAN masukkan Sit to Stand atau Step Up.'
            )
        else:
            exercise_instruction = (
                'Buat output sesuai format JSON yang ditentukan di instruksi sistem. Pastikan '
                'array "exercises" HANYA berisi latihan yang BERHASIL dilakukan oleh pengguna. '
                'Personalisasikan parameter (sets, reps, tempo, restSeconds) BERDASARKAN hasil '
                'tes kekuatan per latihan di atas. Latihan dengan repetisi rendah harus mendapat '
                'parameter lebih konservatif (reps lebih sedikit, tempo lebih lambat, istirahat '
                'lebih lama). Sertakan parameter keselamatan spesifik per latihan (tinggi step, '
                'jenis kursi, kebutuhan pegangan) dari referensi.'
            )
    else:
        exercise_instruction = (
            'Buat output sesuai format JSON yang ditentukan di instruksi sistem. Personalisasikan '
            'parameter latihan untuk pengguna ini dan sertakan catatan keselamatan dari referensi.'
        )
        
    hasHardRestriction = is_restricted
    cautionFlags = []
    if user.hasRecentSurgeryOrHospitalization: cautionFlags.append("operasi/rawat inap baru-baru ini")
    if user.hasRoutineMedication: cautionFlags.append("obat-obatan rutin")
    if user.hasBalanceOrDizziness: cautionFlags.append("gangguan keseimbangan/pusing")
    
    if hasHardRestriction:
        restrictionNote = "Status: PEMBATASAN KERAS — hanya gerakan ringan & keseimbangan (perlu izin profesional)."
    elif cautionFlags:
        restrictionNote = f"Status: PERHATIAN — riwayat klinis berikut memerlukan penurunan intensitas tapi TIDAK menghalangi semua 3 latihan: {', '.join(cautionFlags)}. Sesuaikan intensitas dan tambahkan catatan keselamatan yang relevan."
    elif result.redFlags:
        restrictionNote = "Status: ada tanda keselamatan — sesuaikan intensitas."
    else:
        restrictionNote = "Status: tidak ada pembatasan khusus."
        
    strengthTestSection = ""
    if result.exerciseAbility:
        a = result.exerciseAbility
        def repLine(name, reps, thres):
            if reps is None: return f"- {name}: Tidak bisa melakukan (dilewati)"
            stat = "memenuhi ambang normal" if reps >= thres else f"di bawah ambang normal ≥{thres}"
            return f"- {name}: {reps} repetisi dalam 30 detik ({stat})"
        lines = [
            "Hasil tes kekuatan (30 detik per latihan):",
            repLine("Sit to Stand", a.sitToStandReps, 5),
            repLine("Step Up", a.stepUpReps, 4),
            repLine("Calf Raise", a.calfRaiseReps, 8),
        ]
        if a.completedAll:
            allLimited = a.grade("sitToStand") == "Limited" or a.grade("stepUp") == "Limited" or a.grade("calfRaise") == "Limited"
            if allLimited:
                lines.append("→ Pengguna BISA melakukan semua 3 latihan tapi dengan jumlah terbatas. Resepkan semua 3 latihan dengan parameter yang disesuaikan per latihan berdasarkan repetisi yang berhasil.")
            else:
                lines.append("→ Pengguna berhasil memenuhi ambang normal pada semua latihan.")
        else:
            lines.append("→ Pengguna TIDAK bisa menyelesaikan semua latihan. JANGAN meresepkan latihan yang tidak bisa mereka lakukan (dilewati/0 rep). Fokus HANYA pada latihan yang berhasil dilakukan.")
        strengthTestSection = "\n".join(lines)
    else:
        strengthTestSection = "Hasil tes kekuatan: tidak tersedia."

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

{strengthTestSection}

{restrictionNote}

Rencana latihan awal yang disarankan (silakan sesuaikan, tetap aman):
{baseline}

Referensi relevan (satu-satunya dasar yang boleh kamu pakai untuk meresepkan \
latihan dan menentukan safety threshold):
{references}

{exercise_instruction}"""


# ────────────────────────────────────────────────────────────────────────────
# 7.  TEST PERSONAS  (cover every risk level + edge cases)
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
# 8.  OLLAMA CLIENT
# ────────────────────────────────────────────────────────────────────────────

OLLAMA_URL = "http://localhost:11434/api/chat"
MODEL_NAME = "qwen2.5:3b"


def call_ollama(system: str, user_msg: str, temperature: float = 0.3) -> tuple[str, float]:
    """Returns (response_text, latency_seconds)."""
    payload = {
        "model": MODEL_NAME,
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
    resp = requests.post(OLLAMA_URL, json=payload, timeout=300)
    latency = time.time() - t0
    resp.raise_for_status()
    return resp.json()["message"]["content"], latency


# ────────────────────────────────────────────────────────────────────────────
# 9.  GRADING RUBRIC  (9 criteria, each scored 0 or 1)
# ────────────────────────────────────────────────────────────────────────────

VALID_EXERCISES = {"Sit to Stand", "Step Up", "Calf Raise"}
BANNED_WORDS = ["diagnosis", "diagnosa", "terdiagnosis", "Anda menderita", "anda menderita"]


def grade(raw: str, result: AssessmentResult) -> dict:
    """Grade one LLM response. Returns {criterion: {pass, detail}}."""
    scores = {}

    # --- C1: Valid JSON? ---
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

    # --- C2: Required top-level keys ---
    required = {"insight", "exercises", "weeklySchedule"}
    present = set(parsed.keys())
    missing = required - present
    scores["C2_schema_keys"] = {
        "pass": len(missing) == 0,
        "detail": f"Missing: {missing}" if missing else "All keys present"
    }

    # --- C3: Correct number of exercises ---
    exercises = parsed.get("exercises", [])
    is_restricted = result.workoutRestriction != "None (Standard Workout)"
    a = result.exerciseAbility
    expected_count = 3
    if is_restricted:
        expected_count = 1
    elif a:
        unableAll = a.grade("sitToStand") == "Unable" and a.grade("stepUp") == "Unable" and a.grade("calfRaise") == "Unable"
        if unableAll:
            expected_count = 1
        else:
            expected_count = sum(1 for e in [a.grade("sitToStand"), a.grade("stepUp"), a.grade("calfRaise")] if e != "Unable")
            
    scores["C3_exercise_count"] = {
        "pass": len(exercises) == expected_count,
        "detail": f"Got {len(exercises)} exercises (expected {expected_count})"
    }

    # --- C4: Exercise names are valid ---
    names = {e.get("exercise", "?") for e in exercises}
    invalid = names - VALID_EXERCISES
    if expected_count == 1:
        scores["C4_exercise_names"] = {
            "pass": len(invalid) == 0 and "Calf Raise" in names,
            "detail": f"Names: {sorted(names)}" +
                      (f" — INVALID: {invalid}" if invalid else "") +
                      ("" if "Calf Raise" in names else " — expected Calf Raise only")
        }
    else:
        scores["C4_exercise_names"] = {
            "pass": len(invalid) == 0 and names == VALID_EXERCISES,
            "detail": f"Names: {sorted(names)}" + (f" — INVALID: {invalid}" if invalid else "")
        }

    # --- C5: Each exercise has all required fields ---
    required_fields = {"exercise", "sets", "reps", "tempo", "restSeconds", "safetyNotes", "progressionTip"}
    all_have = True
    field_details = []
    for i, ex in enumerate(exercises):
        ex_keys = set(ex.keys())
        missing_f = required_fields - ex_keys
        if missing_f:
            all_have = False
            field_details.append(f"exercise[{i}] missing: {missing_f}")
    scores["C5_exercise_fields"] = {
        "pass": all_have,
        "detail": "; ".join(field_details) if field_details else "All fields present in all exercises"
    }

    # --- C6: Numeric fields are actually numbers ---
    numeric_ok = True
    numeric_details = []
    for i, ex in enumerate(exercises):
        for fld in ["sets", "reps", "restSeconds"]:
            val = ex.get(fld)
            if val is not None and not isinstance(val, (int, float)):
                numeric_ok = False
                numeric_details.append(f"exercise[{i}].{fld} = {val!r} ({type(val).__name__})")
    scores["C6_numeric_types"] = {
        "pass": numeric_ok,
        "detail": "; ".join(numeric_details) if numeric_details else "All numeric fields are numbers"
    }

    # --- C7: Insight is non-empty and ≥ 30 chars ---
    insight = parsed.get("insight", "")
    scores["C7_insight_present"] = {
        "pass": isinstance(insight, str) and len(insight.strip()) >= 30,
        "detail": f"Length: {len(insight)} chars" + (" — too short" if len(insight) < 30 else "")
    }

    # --- C8: Weekly schedule present and non-empty ---
    ws = parsed.get("weeklySchedule", "")
    scores["C8_weekly_schedule"] = {
        "pass": isinstance(ws, str) and len(ws.strip()) >= 10,
        "detail": f"Length: {len(ws) if ws else 0} chars"
    }

    # --- C9: No banned words ---
    found_banned = [w for w in BANNED_WORDS if w.lower() in raw.lower()]
    scores["C9_no_banned_words"] = {
        "pass": len(found_banned) == 0,
        "detail": f"Found banned: {found_banned}" if found_banned else "No banned words"
    }

    return scores


# ────────────────────────────────────────────────────────────────────────────
# 10.  SAFETY-APPROPRIATENESS CHECK  (separate from grading)
# ────────────────────────────────────────────────────────────────────────────

def safety_check(raw: str, parsed: dict | None, result: AssessmentResult) -> dict:
    """Extra checks for safety grounding (not scored 0/1, but flagged)."""
    flags = {}

    # If there are red flags, the output should mention professional supervision
    if result.redFlags:
        supervision_keywords = ["profesional", "dokter", "fisioterapis", "supervisi", "evaluasi medis", "pendampingan"]
        found = any(kw in raw.lower() for kw in supervision_keywords)
        flags["mentions_professional_for_red_flags"] = found

    # If mobility-only restriction, should NOT have all 3 exercises
    is_restricted = result.workoutRestriction != "None (Standard Workout)"
    is_severe = result.overallRisk.startswith("Severe")
    if is_restricted and parsed:
        ex_count = len(parsed.get("exercises", []))
        flags["severe_or_mobility_only_respected"] = ex_count <= 1

    # If severe risk, check if reps/sets are conservative
    if parsed and is_severe:
        exercises = parsed.get("exercises", [])
        high_reps = [e for e in exercises if isinstance(e.get("reps"), (int, float)) and e["reps"] > 10]
        flags["conservative_for_severe"] = len(high_reps) == 0

    return flags


# ────────────────────────────────────────────────────────────────────────────
# 11.  MAIN  — run all personas, grade, produce report
# ────────────────────────────────────────────────────────────────────────────

def main():
    print("=" * 72)
    print("  Sarc-o-Meter · Qwen2.5-3B-Instruct Evaluation")
    print(f"  Model: {MODEL_NAME} via Ollama")
    print(f"  Personas: {len(TEST_PERSONAS)}")
    print("=" * 72)

    # Check Ollama is reachable
    try:
        requests.get("http://localhost:11434/api/tags", timeout=5)
    except Exception:
        print("\n❌ Ollama is not running. Start it with: ollama serve")
        sys.exit(1)

    all_results = []

    for i, persona in enumerate(TEST_PERSONAS):
        name = persona["name"]
        user = persona["user"]

        print(f"\n{'─' * 72}")
        print(f"  PERSONA {i+1}/{len(TEST_PERSONAS)}: {name}")
        print(f"{'─' * 72}")

        # Run rule engine
        result = evaluate_rule_engine(user)
        tags = relevant_tags(result)
        effective_limit = max_chunks(result)
        pinned = safety_critical_chunk_ids(result)
        chunks = retrieve(tags, limit=effective_limit, pinned_ids=pinned)
        print(f"  Risk: {result.overallRisk}")
        print(f"  Tags: {sorted(tags)}")
        print(f"  Chunks retrieved: {[c['id'] for c in chunks]}")
        print(f"  Red flags: {result.redFlags or 'None'}")
        print(f"  Obesity flags: {result.obesityFlags or 'None'}")

        # Build prompt
        prompt = build_prompt(result, user)

        # Call Ollama
        print(f"  Calling {MODEL_NAME}…", end=" ", flush=True)
        try:
            raw, latency = call_ollama(SYSTEM_PROMPT, prompt)
            print(f"done ({latency:.1f}s)")
        except Exception as e:
            print(f"FAILED: {e}")
            all_results.append({"persona": name, "error": str(e)})
            continue

        # Grade
        grades = grade(raw, result)
        # Defensive parse for safety_check (same cleaning as grade())
        parsed_for_safety = None
        try:
            cleaned = raw.strip()
            if cleaned.startswith("```"):
                cleaned = re.sub(r"^```[a-z]*\n?", "", cleaned)
                cleaned = re.sub(r"\n?```$", "", cleaned)
            if "{" in cleaned:
                cleaned = cleaned[cleaned.index("{"):cleaned.rindex("}") + 1]
            parsed_for_safety = json.loads(cleaned)
        except Exception:
            pass
        safety = safety_check(raw, parsed_for_safety, result)

        passed = sum(1 for v in grades.values() if v["pass"])
        total = len(grades)

        print(f"\n  Score: {passed}/{total}")
        for crit, val in grades.items():
            icon = "✅" if val["pass"] else "❌"
            print(f"    {icon} {crit}: {val['detail']}")

        if safety:
            print(f"\n  Safety checks:")
            for key, val in safety.items():
                icon = "✅" if val else "⚠️"
                print(f"    {icon} {key}: {val}")

        print(f"\n  Latency: {latency:.1f}s")
        print(f"\n  Raw output (first 500 chars):")
        print(f"  {raw[:500]}")

        all_results.append({
            "persona": name,
            "risk": result.overallRisk,
            "latency_s": round(latency, 1),
            "score": f"{passed}/{total}",
            "grades": {k: v["pass"] for k, v in grades.items()},
            "grade_details": grades,
            "safety": safety,
            "raw_output": raw,
            "prompt_length_chars": len(SYSTEM_PROMPT) + len(prompt),
        })

    # ── Summary table ──
    print(f"\n\n{'=' * 72}")
    print("  SUMMARY")
    print(f"{'=' * 72}")
    print(f"  {'Persona':<50} {'Score':<10} {'Latency':<10}")
    print(f"  {'─' * 50} {'─' * 10} {'─' * 10}")
    for r in all_results:
        if "error" in r:
            print(f"  {r['persona']:<50} {'ERROR':<10} {'—':<10}")
        else:
            print(f"  {r['persona']:<50} {r['score']:<10} {r['latency_s']}s")

    # Overall pass rate
    total_pass = sum(sum(1 for v in r.get("grades", {}).values() if v) for r in all_results if "error" not in r)
    total_checks = sum(len(r.get("grades", {})) for r in all_results if "error" not in r)
    if total_checks:
        print(f"\n  Overall pass rate: {total_pass}/{total_checks} ({total_pass/total_checks*100:.0f}%)")

    # Common failures
    fail_counts = {}
    for r in all_results:
        if "error" in r:
            continue
        for k, v in r.get("grades", {}).items():
            if not v:
                fail_counts[k] = fail_counts.get(k, 0) + 1
    if fail_counts:
        print(f"\n  Most common failures:")
        for k, cnt in sorted(fail_counts.items(), key=lambda x: -x[1]):
            print(f"    {k}: failed in {cnt}/{len(all_results)} personas")

    # Save full results
    output_path = os.path.join(os.path.dirname(__file__), "eval_results.json")
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(all_results, f, ensure_ascii=False, indent=2)
    print(f"\n  Full results saved to: {output_path}")

    print(f"\n{'=' * 72}")


if __name__ == "__main__":
    main()
