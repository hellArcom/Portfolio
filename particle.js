// Récupère l'élément canvas et son contexte 2D
const canvas = document.getElementById('particles');
const ctx = canvas.getContext('2d');

// Définit la taille du canvas pour remplir la fenêtre
canvas.width = window.innerWidth;
canvas.height = window.innerHeight;

// Couleur des particules (vous pouvez changer cette valeur)
const particleColor = '#00ffee'; 

// Tableau pour stocker les particules
const particles = [];
// Nombre de particules
const nb = 100; 
// Objet pour suivre la position de la souris
const mouse = { x: null, y: null };

// Classe pour représenter une particule
class Particle {
  constructor() {
    // Position initiale aléatoire
    this.x = Math.random() * canvas.width;
    this.y = Math.random() * canvas.height;
    // Vitesse initiale aléatoire
    this.vx = (Math.random() - 0.5) * 1.2;
    this.vy = (Math.random() - 0.5) * 1.2;
    // Taille de la particule
    this.size = 2;
  }

  // Met à jour la position de la particule
  move() {
    this.x += this.vx;
    this.y += this.vy;
    // Rebondit sur les bords horizontaux
    if (this.x < 0 || this.x > canvas.width) this.vx *= -1;
    // Rebondit sur les bords verticaux
    if (this.y < 0 || this.y > canvas.height) this.vy *= -1;
  }

  // Dessine la particule
  draw() {
    ctx.beginPath();
    ctx.arc(this.x, this.y, this.size, 0, Math.PI * 2);
    ctx.fillStyle = particleColor;
    ctx.fill();
  }
}

// Crée le nombre désiré de particules
for (let i = 0; i < nb; i++) {
  particles.push(new Particle());
}

// Fonction principale d'animation
function animate() {
  // Efface le canvas à chaque frame
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  // Boucle sur chaque particule
  particles.forEach((p, i) => {
    p.move(); // Met à jour la position
    p.draw(); // Dessine la particule

    // Interaction avec la souris
    if (mouse.x && mouse.y) {
      const dx = p.x - mouse.x;
      const dy = p.y - mouse.y;
      const dist = Math.sqrt(dx * dx + dy * dy);
      // Si la souris est proche
      if (dist < 120) {
        // Dessine une ligne entre la particule et la souris
        ctx.beginPath();
        // La ligne devient plus transparente quand elle est plus longue
        ctx.strokeStyle = `rgba(150, 255, 255, ${1 - dist / 120})`; 
        ctx.lineWidth = 0.8;
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(mouse.x, mouse.y);
        ctx.stroke();

        // Repousse légèrement la particule (optionnel)
        // p.x += dx * -0.005; 
        // p.y += dy * -0.005;
      }
    }

    // Interaction entre particules
    for (let j = i; j < particles.length; j++) { // Commence à 'i' pour éviter doublons et auto-connexion
      const dx = p.x - particles[j].x;
      const dy = p.y - particles[j].y;
      const dist = Math.sqrt(dx * dx + dy * dy);
      // Si deux particules sont proches
      if (dist < 100) {
        // Dessine une ligne entre elles
        ctx.beginPath();
        // La ligne devient plus transparente quand elle est plus longue
        ctx.strokeStyle = `rgba(55, 255, 255, ${1 - dist / 100})`; 
        ctx.lineWidth = 0.4;
        ctx.moveTo(p.x, p.y);
        ctx.lineTo(particles[j].x, particles[j].y);
        ctx.stroke();
      }
    }
  });

  // Demande au navigateur d'exécuter 'animate' à la prochaine frame disponible
  requestAnimationFrame(animate);
}

// Lance l'animation
animate();

// Met à jour les coordonnées de la souris quand elle bouge
window.addEventListener('mousemove', e => {
  mouse.x = e.clientX;
  mouse.y = e.clientY;
});

// Réinitialise la position de la souris quand elle quitte la fenêtre
window.addEventListener('mouseout', () => {
    mouse.x = null;
    mouse.y = null;
});

// Redimensionne le canvas si la taille de la fenêtre change
window.addEventListener('resize', () => {
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;
  // Optionnel: Recréer les particules peut éviter qu'elles se retrouvent hors champ
  // particles.length = 0; // Vide le tableau
  // for (let i = 0; i < nb; i++) {
  //   particles.push(new Particle());
  // }
});
