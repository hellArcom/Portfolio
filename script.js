document.addEventListener('DOMContentLoaded', () => {
    // Add class for animation fallback
    document.documentElement.classList.add('js-enabled');
    
    // 1. Initial Icon Load
    const initIcons = () => {
        if (typeof lucide !== 'undefined') {
            lucide.createIcons();
        }
    };
    initIcons();

    // 2. Preloader with safety timeout
    const loader = document.getElementById('loader');
    const hideLoader = () => {
        if (!loader) return;
        loader.style.opacity = '0';
        setTimeout(() => {
            loader.style.visibility = 'hidden';
        }, 600);
    };

    window.addEventListener('load', hideLoader);
    setTimeout(hideLoader, 3000); 

    // 3. Three.js Particles Background
    const initThree = () => {
        try {
            const container = document.getElementById('canvas-container');
            if (!container || typeof THREE === 'undefined') return null;

            const scene = new THREE.Scene();
            const camera = new THREE.PerspectiveCamera(75, window.innerWidth / window.innerHeight, 0.1, 1000);
            
            // Optimization: Disable antialias and use high-performance power preference
            const renderer = new THREE.WebGLRenderer({ 
                alpha: true, 
                antialias: false,
                powerPreference: 'high-performance'
            });
            
            renderer.setSize(window.innerWidth, window.innerHeight);
            renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
            container.appendChild(renderer.domElement);

            const particlesGeometry = new THREE.BufferGeometry();
            // Optimization: Significantly reduced particle count (from 80k to 15k)
            const particlesCount = 15000;
            const posArray = new Float32Array(particlesCount * 3);

            for (let i = 0; i < particlesCount * 3; i++) {
                posArray[i] = (Math.random() - 0.5) * 10;
            }

            particlesGeometry.setAttribute('position', new THREE.BufferAttribute(posArray, 3));
            
            // Create a circular texture for better looking particles
            const createCircleTexture = () => {
                const canvas = document.createElement('canvas');
                canvas.width = 64;
                canvas.height = 64;
                const ctx = canvas.getContext('2d');
                const gradient = ctx.createRadialGradient(32, 32, 0, 32, 32, 32);
                gradient.addColorStop(0, 'rgba(255, 255, 255, 1)');
                gradient.addColorStop(0.5, 'rgba(255, 255, 255, 0.5)');
                gradient.addColorStop(1, 'rgba(255, 255, 255, 0)');
                ctx.fillStyle = gradient;
                ctx.fillRect(0, 0, 64, 64);
                return new THREE.CanvasTexture(canvas);
            };

            const material = new THREE.PointsMaterial({
                size: 0.012, // Slightly larger to compensate for lower count
                color: '#00d2ff',
                transparent: true,
                opacity: 0.8,
                blending: THREE.AdditiveBlending,
                map: createCircleTexture(),
                depthWrite: false // Optimization for transparent particles
            });

            const particlesMesh = new THREE.Points(particlesGeometry, material);
            scene.add(particlesMesh);
            camera.position.z = 3;

            let mouseX = window.innerWidth / 2;
            let mouseY = window.innerHeight / 2;

            document.addEventListener('mousemove', (e) => {
                mouseX = e.clientX;
                mouseY = e.clientY;
            });

            const animate = () => {
                requestAnimationFrame(animate);
                
                const targetX = (mouseX / window.innerWidth - 0.5) * 0.5;
                const targetY = (mouseY / window.innerHeight - 0.5) * 0.5;
                
                particlesMesh.rotation.x += (targetY - particlesMesh.rotation.x) * 0.05;
                particlesMesh.rotation.y += 0.001 + (targetX - particlesMesh.rotation.y) * 0.05;

                renderer.render(scene, camera);
            };
            animate();

            window.addEventListener('resize', () => {
                camera.aspect = window.innerWidth / window.innerHeight;
                camera.updateProjectionMatrix();
                renderer.setSize(window.innerWidth, window.innerHeight);
            });

            return { material };
        } catch (e) {
            console.error('Three.js failed to init:', e);
            return null;
        }
    };

    const threeBg = initThree();

    // 4. Theme Toggle Logic (Fixed null reference)
    const themeToggle = document.getElementById('theme-toggle');
    const html = document.documentElement;

    const setTheme = (theme) => {
        html.setAttribute('data-theme', theme);
        localStorage.setItem('portfolio-theme', theme);
        
        // Robust icon update: replace innerHTML to avoid null reference after Lucide replaces <i>
        if (themeToggle) {
            const iconName = theme === 'dark' ? 'moon' : 'sun';
            themeToggle.innerHTML = `<i data-lucide="${iconName}"></i>`;
            if (typeof lucide !== 'undefined') {
                lucide.createIcons();
            }
        }
        
        if (threeBg && threeBg.material) {
            threeBg.material.color.set(theme === 'dark' ? '#00d2ff' : '#0072ff');
        }
    };

    if (themeToggle) {
        themeToggle.addEventListener('click', () => {
            const newTheme = html.getAttribute('data-theme') === 'dark' ? 'light' : 'dark';
            setTheme(newTheme);
        });
    }

    const savedTheme = localStorage.getItem('portfolio-theme') || 'dark';
    setTheme(savedTheme);

    // 5. Scroll Reveal
    const revealElements = document.querySelectorAll('.reveal');
    const revealObserver = new IntersectionObserver((entries) => {
        entries.forEach(entry => {
            if (entry.isIntersecting) {
                entry.target.classList.add('active');
            }
        });
    }, { threshold: 0.15 });

    revealElements.forEach(el => revealObserver.observe(el));

    // 6. Navbar Effect
    const navbar = document.querySelector('.navbar');
    window.addEventListener('scroll', () => {
        if (!navbar) return;
        if (window.scrollY > 50) {
            navbar.classList.add('scrolled');
        } else {
            navbar.classList.remove('scrolled');
        }
    });

    // 7. Mobile Menu Toggle
    const mobileBtn = document.querySelector('.mobile-toggle');
    const navLinks = document.querySelector('.nav-links');

    if (mobileBtn && navLinks) {
        mobileBtn.addEventListener('click', () => {
            navLinks.classList.toggle('active');
            const isActive = navLinks.classList.contains('active');
            mobileBtn.innerHTML = `<i data-lucide="${isActive ? 'x' : 'menu'}"></i>`;
            if (typeof lucide !== 'undefined') {
                lucide.createIcons();
            }
        });
        
        navLinks.querySelectorAll('a').forEach(link => {
            link.addEventListener('click', () => {
                navLinks.classList.remove('active');
                mobileBtn.innerHTML = `<i data-lucide="menu"></i>`;
                if (typeof lucide !== 'undefined') {
                    lucide.createIcons();
                }
            });
        });
    }

    // 8. Smooth Scroll
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();
            const target = document.querySelector(this.getAttribute('href'));
            if (target) {
                window.scrollTo({
                    top: target.offsetTop - 80,
                    behavior: 'smooth'
                });
            }
        });
    });
});
