# Sarc-O-Meter

Sarc-O-Meter is an intelligent, on-device application designed for early screening and assessment of sarcopenia. By leveraging computer vision, machine learning, and large language models (LLM), Sarc-O-Meter provides an end-to-end, automated pipeline to assess muscle mass, strength, and overall sarcopenia risk, without requiring manual clinical measurements.

## The Three-Tier Architecture System

The Sarc-O-Meter application is built upon a robust three-tier architecture, ensuring seamless data flow from image capture to intelligent clinical insights:

### Tier 1: Body Pose Estimation
At the foundation of the pipeline is the **Body Pose Estimation** tier. 
* **How it works:** This tier uses the device's camera to capture the user's body. It leverages advanced Vision frameworks and Core ML to perform real-time body pose detection, tracking key joints and body landmarks. During static capture, it generates an accurate silhouette for measurements. During physical tests and exercises (e.g., sit-to-stand, step-up, calf raise), it actively tracks body movement angles and form.
* **Purpose:** To digitize the user's physical structure for automated body measurements, and to act as an intelligent motion tracker that provides automated repetition counting, form scoring, and real-time angle feedback during strength tests and exercises.

### Tier 2: Automated Body Measurements & Integration
The intermediate tier is the **Automated Body Measurements & Integration** system.
* **How it works:** Once the silhouette and pose landmarks are identified, this tier mathematically calculates 14 key body measurements, most notably calf circumference (for muscle mass estimation) and waist circumference (for central obesity). These measurements are then integrated into the deterministic Sarcopenia Rule Engine (based on AWGS 2019 criteria), which classifies the user's risk level and evaluates exercise performance (e.g., sit-to-stand, step-up, calf raise).
* **Purpose:** To translate raw pixel and pose data into actionable clinical metrics, providing a deterministic and reliable risk classification (Normal, Limited, Abnormal) entirely on-device.

### Tier 3: LLM and RAG Implementation
The top tier is the **Large Language Model (LLM) and Retrieval-Augmented Generation (RAG)** system.
* **How it works:** After the rule engine has classified the user's risk and gathered the automated measurements, this tier takes over to provide personalized, human-readable insights. By utilizing an LLM augmented with RAG (retrieving specific clinical guidelines, sarcopenia research, and personalized exercise databases), the system generates tailored exercise plans, and easy-to-understand health summaries for the user.
* **Purpose:** To bridge the gap between raw clinical data and user experience, delivering an empathetic, personalized, and medically sound interpretation of the results.

---

## Team Contributions

The development of Sarc-O-Meter was made possible by the dedicated efforts of our team, with each member taking ownership of a critical tier in the system:

* **Kemal Dwi Heldy Muhammad** 
  * *Role:* Automated Body Measurements and Integration 
  * *Focus:* Developed the logic to accurately extract 14 body measurements from visual data and integrated these metrics into the deterministic screening and rule engine to evaluate sarcopenia risk.

* **Surya Ramadhani**
  * *Role:* Body Pose Estimation
  * *Focus:* Engineered the on-device Core ML and Vision pipeline for real-time person segmentation and pose detection. This encompasses static silhouette generation for automated body measurements, as well as real-time joint tracking to calculate body movement angles and enable automated rep counting during strength tests and exercises.

* **Vira Fitriyani**
  * *Role:* LLM and RAG Implementation
  * *Focus:* Built the intelligent insight generator using Large Language Models and RAG architecture, enabling the application to provide personalized health summaries, risk explanations, and customized exercise plans based on the user's unique data.
